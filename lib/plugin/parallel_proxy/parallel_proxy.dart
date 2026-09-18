import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A loopback HTTP server that mirrors a single remote file, fetching it from
/// the CDN in several concurrent byte ranges and re-serialising the result into
/// one ordinary Range-capable stream.
///
/// The player (libmpv, via media_kit) sees a plain HTTP file server and needs
/// no knowledge of any of this. Point it at [ParallelProxy.register]'s return
/// value instead of the bilibili URL.
class ParallelProxyConfig {
  const ParallelProxyConfig({
    this.concurrency = 16,
    this.chunkSize = 1 << 20,
    this.minParallelSize = 256 << 10,
    this.spreadAcrossMirrors = false,
    this.maxConnectionsPerHost,
    this.maxAttemptsPerChunk = 3,
    this.connectTimeout = const Duration(seconds: 10),
    this.chunkTimeout = const Duration(seconds: 30),
    this.mirrorPenalty = const Duration(seconds: 30),
  });

  /// Range requests in flight per client request. Memory held by one playing
  /// video is bounded by [concurrency] * [chunkSize] (16 MiB by default), and
  /// that product is also the effective read-ahead ceiling.
  ///
  /// Measure with `bin/bench.dart` rather than guessing - the useful value is
  /// a property of the route, not of this code. Lower it on cellular and on
  /// older phones, where the handshakes and radio wakeups cost more than the
  /// extra throughput is worth.
  final int concurrency;

  /// Bytes per range request. Too small and per-request overhead dominates;
  /// too large and one slow node stalls the ordered write.
  final int chunkSize;

  /// Requests smaller than this are fetched on one connection. FFmpeg probes
  /// the file header before playback and there is nothing to parallelise in a
  /// few KiB.
  final int minParallelSize;

  /// Whether to spread chunks evenly over every mirror, or hold the primary
  /// and treat the rest as failover only.
  ///
  /// Defaults to failover-only because the throttling that makes this proxy
  /// worthwhile is usually per-connection rather than per-host: when that is
  /// true, spreading buys nothing and actively drags throughput toward the
  /// slowest mirror. Turn it on only if `bin/bench.dart` shows all mirrors
  /// together beating the best one alone.
  final bool spreadAcrossMirrors;

  /// Cap on simultaneous sockets to one host, shared by every registration.
  ///
  /// It must cover the SUM of all streams playing at once, not one stream:
  /// a DASH video and its audio track usually live on the same CDN host, so a
  /// cap sized for the video alone would silently throttle the pair. Defaults
  /// to [concurrency] * 3 for that headroom.
  final int? maxConnectionsPerHost;

  final int maxAttemptsPerChunk;
  final Duration connectTimeout;
  final Duration chunkTimeout;

  /// How long a mirror is skipped after it fails or returns a bad range.
  final Duration mirrorPenalty;
}

/// Thrown internally when the player hangs up; unwinds the fetch pipeline
/// without logging it as a failure.
class _Cancelled implements Exception {
  const _Cancelled();
}

class _Upstream {
  _Upstream(this.mirrors, this.headers, this.concurrency);

  final List<Uri> mirrors;
  final Map<String, String> headers;

  /// Range requests in flight for this file specifically. A DASH audio track
  /// is a fraction of the video bitrate and does not need the video's
  /// parallelism - spending it there is just handshakes and radio wakeups.
  final int concurrency;
  final Map<Uri, DateTime> _penalised = {};

  int _cursor = 0;
  int? totalLength;
  String contentType = 'video/mp4';

  /// Picks a mirror, skipping ones that recently misbehaved.
  ///
  /// With [spread] false this holds the primary and only moves to a backup
  /// once the primary is penalised. With it true, chunks round-robin across
  /// every healthy mirror. If all of them are penalised we use one anyway -
  /// a degraded mirror beats refusing to serve.
  Uri pick({required bool spread}) {
    final now = DateTime.now();
    final from = spread ? _cursor : 0;
    for (var i = 0; i < mirrors.length; i++) {
      final index = (from + i) % mirrors.length;
      final uri = mirrors[index];
      final until = _penalised[uri];
      if (until == null || now.isAfter(until)) {
        if (spread) _cursor = (index + 1) % mirrors.length;
        return uri;
      }
    }
    return spread ? mirrors[_cursor++ % mirrors.length] : mirrors.first;
  }

  void penalise(Uri uri, Duration penalty) {
    if (mirrors.length > 1) _penalised[uri] = DateTime.now().add(penalty);
  }
}

/// Per-client-request state. One [_Session] exists for each GET the player
/// makes; when the player seeks it drops the socket and a new session starts.
class _Session {
  _Session(this.upstream);

  final _Upstream upstream;
  bool cancelled = false;
}

class _ByteRange {
  const _ByteRange(this.start, this.end, this.isPartial);

  final int start;
  final int end; // inclusive
  final bool isPartial;

  int get length => end - start + 1;
}

class ParallelProxy {
  ParallelProxy({this.config = const ParallelProxyConfig()});

  final ParallelProxyConfig config;

  HttpServer? _server;
  late final HttpClient _client = HttpClient()
    // dart:io defaults to 6 connections per host, which would silently cap
    // concurrency no matter what we schedule.
    ..maxConnectionsPerHost =
        config.maxConnectionsPerHost ?? config.concurrency * 3
    // Transparent gzip would corrupt byte accounting.
    ..autoUncompress = false
    ..connectionTimeout = config.connectTimeout
    ..idleTimeout = const Duration(seconds: 15);

  final Map<String, _Upstream> _upstreams = {};
  final Random _rng = Random.secure();

  int get port => _server!.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    // Loopback only, OS-assigned port: nothing else on the device can reach it
    // and we cannot collide with another app.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      (req) => _handle(req).catchError((_) {}),
      onError: (_) {},
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _upstreams.clear();
    _client.close(force: true);
  }

  /// Registers a remote file and returns the loopback URL to hand the player.
  ///
  /// [url] is the DASH baseUrl; [backupUrls] are the mirror hosts bilibili
  /// returns alongside it. [headers] must carry the Referer and User-Agent the
  /// CDN expects, or the mirrors answer 403.
  ///
  /// Register the video and audio tracks separately - bilibili serves them as
  /// two files - and give audio a smaller [concurrency], since it carries a
  /// fraction of the bitrate.
  String register({
    required String url,
    List<String> backupUrls = const [],
    Map<String, String> headers = const {},
    int? concurrency,
  }) {
    if (_server == null) {
      throw StateError('ParallelProxy.start() must be awaited first');
    }
    final mirrors = <Uri>[
      Uri.parse(url),
      for (final b in backupUrls) Uri.parse(b),
    ];
    // The signed playurl query string is long and awkward to nest inside
    // another query parameter, so hand out an opaque token instead.
    final token = List.generate(
      16,
      (_) => _rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _upstreams[token] = _Upstream(
      mirrors,
      Map.unmodifiable(headers),
      concurrency ?? config.concurrency,
    );
    return 'http://127.0.0.1:$port/v/$token';
  }

  void unregister(String localUrl) {
    _upstreams.remove(Uri.parse(localUrl).pathSegments.last);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final segments = req.uri.pathSegments;

    if (segments.length != 2 || segments.first != 'v') {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    final upstream = _upstreams[segments[1]];
    if (upstream == null) {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      return res.close();
    }

    final session = _Session(upstream);
    // The player seeking == the player closing this socket. Flag it so the
    // in-flight chunk fetches abort instead of finishing work nobody wants.
    unawaited(res.done.then((_) {}, onError: (_) => session.cancelled = true));

    final int total;
    try {
      total = await _resolveLength(session);
    } catch (_) {
      res.statusCode = HttpStatus.badGateway;
      return res.close();
    }

    final range = _parseRange(
      req.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range == null) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      return res.close();
    }

    res.statusCode = range.isPartial
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, upstream.contentType);
    if (range.isPartial) {
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$total',
      );
    }
    res.contentLength = range.length;

    if (req.method == 'HEAD') return res.close();

    try {
      await _pump(session, range, res);
    } on _Cancelled {
      // Expected on every seek.
    } catch (_) {
      // Half-written body; closing is all we can do, the player will retry.
    } finally {
      session.cancelled = true;
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Streams [range] to [res] in order, keeping this upstream's concurrency
  /// worth of range requests in flight.
  ///
  /// Read-ahead needs no heuristic: we only ever schedule a bounded window past
  /// the write cursor, and flush() blocks once libmpv stops draining the
  /// socket, which stops the loop scheduling more. The player's own cache size
  /// governs how far ahead we run.
  Future<void> _pump(
    _Session session,
    _ByteRange range,
    HttpResponse res,
  ) async {
    if (range.length < config.minParallelSize) {
      res.add(await _fetchChunk(session, range.start, range.end));
      await res.flush();
      return;
    }

    final inFlight = Queue<Future<Uint8List>>();
    var nextOffset = range.start;

    try {
      while (nextOffset <= range.end || inFlight.isNotEmpty) {
        while (inFlight.length < session.upstream.concurrency &&
            nextOffset <= range.end &&
            !session.cancelled) {
          final end = min(nextOffset + config.chunkSize - 1, range.end);
          inFlight.add(_fetchChunk(session, nextOffset, end));
          nextOffset = end + 1;
        }
        if (inFlight.isEmpty) break;

        final bytes = await inFlight.removeFirst();
        if (session.cancelled) throw const _Cancelled();

        res.add(bytes);
        // Backpressure: this is what stops us racing ahead of playback.
        await res.flush();
      }
    } finally {
      session.cancelled = true;
      // Futures are not cancellable; the flag aborts them at their next read.
      // Swallow their errors so they do not surface as unhandled.
      for (final f in inFlight) {
        unawaited(f.then((_) {}, onError: (_) {}));
      }
    }
  }

  /// Fetches [start]-[end] inclusive, rotating mirrors on failure.
  Future<Uint8List> _fetchChunk(_Session session, int start, int end) async {
    Object? lastError;
    for (var attempt = 0; attempt < config.maxAttemptsPerChunk; attempt++) {
      if (session.cancelled) throw const _Cancelled();
      final uri = session.upstream.pick(spread: config.spreadAcrossMirrors);
      try {
        return await _fetchOnce(
          session,
          uri,
          start,
          end,
        ).timeout(config.chunkTimeout);
      } on _Cancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        session.upstream.penalise(uri, config.mirrorPenalty);
      }
    }
    throw HttpException('chunk $start-$end failed: $lastError');
  }

  Future<Uint8List> _fetchOnce(
    _Session session,
    Uri uri,
    int start,
    int end,
  ) async {
    final expected = end - start + 1;
    final req = await _client.getUrl(uri);
    session.upstream.headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final resp = await req.close();

    // A node that ignores Range and starts streaming the whole file from zero
    // is worse than useless: it would corrupt the stream and saturate the link.
    if (resp.statusCode != HttpStatus.partialContent) {
      unawaited(resp.drain<void>().catchError((_) {}));
      throw HttpException('expected 206, got ${resp.statusCode} from $uri');
    }
    final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (!_contentRangeMatches(contentRange, start, end)) {
      unawaited(resp.drain<void>().catchError((_) {}));
      throw HttpException('bad content-range "$contentRange" from $uri');
    }

    final builder = BytesBuilder(copy: false);
    await for (final part in resp) {
      // Throwing out of await-for cancels the subscription, which closes the
      // socket: this is how a seek stops paying for bytes already requested.
      if (session.cancelled) throw const _Cancelled();
      builder.add(part);
      if (builder.length > expected) {
        throw HttpException('overlong chunk from $uri');
      }
    }
    if (builder.length != expected) {
      throw HttpException('short chunk from $uri');
    }
    return builder.takeBytes();
  }

  /// Learns the file size with a one-byte range request. CDNs handle these
  /// more consistently than HEAD, and it doubles as a reachability check.
  Future<int> _resolveLength(_Session session) async {
    final cached = session.upstream.totalLength;
    if (cached != null) return cached;

    Object? lastError;
    for (var attempt = 0; attempt < config.maxAttemptsPerChunk; attempt++) {
      final uri = session.upstream.pick(spread: config.spreadAcrossMirrors);
      try {
        final req = await _client.getUrl(uri);
        session.upstream.headers.forEach(req.headers.set);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final resp = await req.close().timeout(config.connectTimeout);
        final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
        final mimeType = resp.headers.contentType?.mimeType;
        await resp.drain<void>().catchError((_) {});

        final total = _totalFromContentRange(contentRange);
        if (total == null) throw HttpException('no content-range from $uri');

        session.upstream.totalLength = total;
        if (mimeType != null && mimeType != 'application/octet-stream') {
          session.upstream.contentType = mimeType;
        }
        return total;
      } catch (e) {
        lastError = e;
        session.upstream.penalise(uri, config.mirrorPenalty);
      }
    }
    throw HttpException('could not resolve length: $lastError');
  }
}

bool _contentRangeMatches(String? header, int start, int end) {
  if (header == null) return false;
  final m = RegExp(r'^bytes\s+(\d+)-(\d+)/').firstMatch(header.trim());
  if (m == null) return false;
  return int.parse(m.group(1)!) == start && int.parse(m.group(2)!) == end;
}

int? _totalFromContentRange(String? header) {
  if (header == null) return null;
  final m = RegExp(r'/(\d+)\s*$').firstMatch(header.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

/// Parses `bytes=N-`, `bytes=N-M` and `bytes=-N`. Returns null if the range is
/// syntactically valid but unsatisfiable.
_ByteRange? _parseRange(String? header, int total) {
  if (total <= 0) return null;
  if (header == null) return _ByteRange(0, total - 1, false);

  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return _ByteRange(0, total - 1, false);

  final rawStart = m.group(1)!;
  final rawEnd = m.group(2)!;
  if (rawStart.isEmpty && rawEnd.isEmpty) {
    return _ByteRange(0, total - 1, false);
  }

  int start;
  int end;
  if (rawStart.isEmpty) {
    // Suffix form: last N bytes. FFmpeg uses this hunting for a trailing moov.
    final n = int.parse(rawEnd);
    if (n == 0) return null;
    start = max(0, total - n);
    end = total - 1;
  } else {
    start = int.parse(rawStart);
    end = rawEnd.isEmpty ? total - 1 : min(int.parse(rawEnd), total - 1);
  }
  if (start >= total || end < start) return null;
  return _ByteRange(start, end, true);
}
