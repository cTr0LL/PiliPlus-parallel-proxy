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
    this.initialConcurrency = 2,
    this.chunkSize = 1 << 20,
    this.minParallelSize = 256 << 10,
    this.spreadAcrossMirrors = false,
    this.maxConnectionsPerHost,
    this.onLog,
    this.maxAttemptsPerChunk = 5,
    this.tcpConnectTimeout = const Duration(seconds: 4),
    this.connectTimeout = const Duration(seconds: 20),
    this.chunkTimeout = const Duration(seconds: 25),
    this.transientPenalty = const Duration(seconds: 2),
    this.retryBackoff = const Duration(milliseconds: 250),
    this.maxRetryBackoff = const Duration(seconds: 4),
    this.scheduleStagger = const Duration(milliseconds: 25),
    this.mirrorPenalty = const Duration(seconds: 30),
    this.maxHostBlock = const Duration(minutes: 5),
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

  /// Connections opened before any bytes have arrived, widening toward
  /// [concurrency] as chunks complete.
  ///
  /// An object that is not cached at the edge has to be pulled from origin, and
  /// N parallel range requests against a cold object means N concurrent origin
  /// pulls - which is how a CDN decides to answer 503 instead. Starting narrow
  /// warms it politely, and the ramp costs nothing once it is warm. This is why
  /// a video could fail on first open and then play instantly on the second
  /// try: the failed attempt was what warmed the edge.
  final int initialConcurrency;

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

  /// Called with a one-line description of each request served and each upstream
  /// failure. Null in release builds.
  ///
  /// A callback rather than a direct `debugPrint` so this file keeps no
  /// dependency on Flutter and stays runnable from plain `dart run`. Without
  /// this, a player that refuses to open a url looks identical to a player that
  /// never tried, and the only way to tell them apart is reading socket tables.
  final void Function(String message)? onLog;

  final int maxAttemptsPerChunk;

  /// Ceiling on opening the TCP/TLS connection itself.
  ///
  /// Deliberately much shorter than [connectTimeout]: reaching a live host
  /// takes well under a second, so a long value here is only ever spent on
  /// hosts that are unreachable. Mainland mirrors often are, from outside
  /// China - and at 20s each, five attempts on the length probe burns 100
  /// seconds before a single byte is served, which the player will not wait
  /// for.
  final Duration tcpConnectTimeout;

  /// Ceiling on the whole request up to response headers. Generous, because an
  /// object that is not cached at the edge has to be pulled from origin first.
  final Duration connectTimeout;

  /// How long a chunk may go with NO bytes arriving before it is abandoned.
  /// An idle timeout, not a total one - any progress resets it - so this is
  /// the "this connection is dead" threshold, not "this chunk is slow".
  final Duration chunkTimeout;

  /// Applied to a mirror after a dropped or stalled connection, as opposed to
  /// a wrong answer. Just long enough that the next attempt picks a different
  /// mirror.
  final Duration transientPenalty;

  /// Base block applied to a host that is unreachable or answers wrongly,
  /// doubling on each consecutive failure up to [maxHostBlock].
  final Duration mirrorPenalty;

  /// Ceiling on the per-host block, so a host that recovers is eventually
  /// retried rather than written off for the life of the app.
  final Duration maxHostBlock;

  /// Delay before the first retry of a chunk, doubling each attempt up to
  /// [maxRetryBackoff]. Without it a struggling CDN gets hit harder exactly
  /// when it is asking to be hit less.
  final Duration retryBackoff;
  final Duration maxRetryBackoff;

  /// Gap between opening each connection in the initial window. Opening the
  /// whole window in one tick looks like a burst to the far end; spreading it
  /// over a few tens of milliseconds costs nothing and reads as normal traffic.
  final Duration scheduleStagger;
}

/// Thrown internally when the player hangs up; unwinds the fetch pipeline
/// without logging it as a failure.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// A mirror that answered incorrectly - wrong status, wrong range, too many
/// bytes. Distinct from a dropped connection, which is a property of the route
/// rather than of the mirror and must not count against it.
class _BadMirror implements Exception {
  const _BadMirror(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Per-host health, shared by every registration.
///
/// Keyed by authority (host AND port) rather than host alone: two origins on
/// the same host but different ports are different servers, and conflating
/// them makes a healthy one inherit a dead one's block.
///
/// Deliberately keyed by host and owned by the proxy rather than by a single
/// file: hosts are reused across videos, so learning that one is unreachable
/// should not have to be re-learned on every playback. A mainland mirror that
/// cannot be reached from this network otherwise costs a fresh connect
/// timeout at the start of every single video.
class _HostHealth {
  int consecutiveFailures = 0;
  DateTime? blockedUntil;

  bool get usable {
    final until = blockedUntil;
    return until == null || DateTime.now().isAfter(until);
  }

  /// Backs off further each time, the way cdn-resolver.js does, so a host
  /// that is simply unreachable stops being tried at all rather than costing
  /// a timeout every half minute.
  void fail(Duration base, Duration cap) {
    consecutiveFailures++;
    var delay = base * (1 << (consecutiveFailures - 1).clamp(0, 8));
    if (delay > cap) delay = cap;
    blockedUntil = DateTime.now().add(delay);
  }

  /// Eases the failure count, but deliberately does NOT lift an active block.
  ///
  /// Requests are in flight when a block is set, so one of them completing
  /// afterwards must not undo a block earned by repeated failures. An
  /// intermittently reachable host - a mainland mirror that answers perhaps one
  /// connection in five - would otherwise unblock itself immediately and be
  /// picked again, paying another connect timeout, forever. The block expires
  /// on its own; success only shortens the NEXT one.
  void succeed() {
    if (consecutiveFailures > 0) consecutiveFailures--;
  }
}
class _Upstream {
  _Upstream(this.mirrors, this.headers, this.concurrency);

  final List<Uri> mirrors;
  final Map<String, String> headers;

  /// Range requests in flight for this file specifically. A DASH audio track
  /// is a fraction of the video bitrate and does not need the video's
  /// parallelism - spending it there is just handshakes and radio wakeups.
  final int concurrency;

  int _cursor = 0;
  int? totalLength;
  String contentType = 'video/mp4';

  /// Requests currently being served from this file.
  ///
  /// Needed because a player can walk away from a stream without closing the
  /// socket: mpv does exactly that when you leave a video. `res.done` then
  /// never errors, the pump sits blocked on flush, and its chunk fetches go on
  /// consuming the per-host connection budget. Enough abandoned streams and a
  /// NEW video cannot get connections and fails to open at all.
  final Set<_Session> sessions = {};

}

/// Per-client-request state. One [_Session] exists for each GET the player
/// makes; when the player seeks it drops the socket and a new session starts.
class _Session {
  _Session(this.upstream);

  final _Upstream upstream;
  bool cancelled = false;

  /// Abort hooks for the requests this session has in flight.
  ///
  /// Setting [cancelled] alone is not enough: a request still waiting on
  /// response headers has no data event to observe the flag, so it holds its
  /// connection until the connect timeout expires - precisely when a seek
  /// needs those connections back. Aborting releases them at once.
  final Set<void Function()> aborts = {};

  void cancel() {
    cancelled = true;
    for (final abort in aborts.toList()) {
      abort();
    }
    aborts.clear();
  }
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
    ..connectionTimeout = config.tcpConnectTimeout
    ..idleTimeout = const Duration(seconds: 15);

  final Map<String, _Upstream> _upstreams = {};
  final Map<String, _HostHealth> _hostHealth = {};
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
    for (final upstream in _upstreams.values) {
      for (final session in upstream.sessions) {
        session.cancel();
      }
    }
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

  /// Drops a registration and stops anything still being served from it.
  void unregister(String localUrl) {
    final upstream = _upstreams.remove(Uri.parse(localUrl).pathSegments.last);
    if (upstream == null) return;
    if (upstream.sessions.isNotEmpty) {
      config.onLog?.call(
        'cancelling ${upstream.sessions.length} live session(s) on unregister',
      );
      // Stopping these is the point of unregistering: the fetches they have in
      // flight are for a stream nobody is watching any more.
      for (final session in upstream.sessions) {
        session.cancel();
      }
      upstream.sessions.clear();
    }
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
      // Most likely an evicted registration: the caller kept only the most
      // recent few and the player came back for an older one.
      config.onLog?.call('${segments[1].substring(0, 8)} 404 unknown token');
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      return res.close();
    }

    final tag = segments[1].substring(0, 8);
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    config.onLog?.call('$tag ${req.method} range=${rangeHeader ?? 'none'}');

    // A player reads one position at a time from a given file, so a new request
    // supersedes any earlier one on the same registration. This is not an
    // optimisation: mpv does not close the previous connection when it seeks or
    // re-opens, so res.done never errors and the old pump keeps fetching. A
    // handful of seeks is enough to exhaust the per-host connection budget and
    // stall the stream the player is actually waiting on.
    if (upstream.sessions.isNotEmpty) {
      config.onLog?.call(
        '$tag superseding ${upstream.sessions.length} earlier session(s)',
      );
      for (final previous in upstream.sessions) {
        previous.cancel();
      }
      upstream.sessions.clear();
    }

    final session = _Session(upstream);
    upstream.sessions.add(session);
    // The player seeking == the player closing this socket. Flag it so the
    // in-flight chunk fetches abort instead of finishing work nobody wants.
    unawaited(res.done.then((_) {}, onError: (_) => session.cancelled = true));

    final int total;
    try {
      total = await _resolveLength(session);
    } catch (e) {
      // The player reports this only as "could not open source file", so say
      // what actually went wrong upstream.
      config.onLog?.call('$tag 502 could not resolve length: $e');
      res.statusCode = HttpStatus.badGateway;
      return res.close();
    }

    final range = _parseRange(
      req.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range == null) {
      config.onLog?.call('$tag 416 unsatisfiable range=$rangeHeader of $total');
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
      upstream.sessions.remove(session);
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
    // Only the opening burst is staggered. Once bytes are flowing, chunks are
    // scheduled one at a time as earlier ones complete, which is already
    // paced - delaying those would just throttle steady-state streaming.
    var openingBurst = true;
    // Slow start. Widens on every completed chunk, so a warm stream reaches
    // full width within a few chunks while a cold one is not hammered.
    var window = config.initialConcurrency.clamp(1, session.upstream.concurrency);

    try {
      while (nextOffset <= range.end || inFlight.isNotEmpty) {
        while (inFlight.length < window &&
            nextOffset <= range.end &&
            !session.cancelled) {
          final end = min(nextOffset + config.chunkSize - 1, range.end);
          final chunk = (openingBurst && inFlight.isNotEmpty)
              ? _staggered(session, nextOffset, end, inFlight.length)
              : _fetchChunk(session, nextOffset, end);
          // Attach a listener now, not just in `finally`: while the pump is
          // blocked on flush these are not being awaited, so a cancellation
          // would otherwise escape as an unhandled async error.
          unawaited(chunk.then((_) {}, onError: (_) {}));
          inFlight.add(chunk);
          nextOffset = end + 1;
        }
        if (inFlight.isEmpty) break;

        final bytes = await inFlight.removeFirst();
        if (session.cancelled) throw const _Cancelled();

        res.add(bytes);
        openingBurst = false;
        // Bytes arrived, so the far end is willing to serve us: widen.
        window = min(session.upstream.concurrency, window * 2);
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

  /// Fetches [start]-[end] inclusive, RESUMING where a dropped connection left
  /// off, and rotating mirrors on a genuine mirror fault.
  ///
  /// Resuming matters far more than it sounds. On a long-haul route the CDN
  /// cuts transfers mid-body routinely, and restarting the chunk from zero each
  /// time spends an attempt to re-fetch bytes already in hand. Exhaust the
  /// attempts and the whole ordered stream dies, which the player surfaces only
  /// as "could not open source file".
  Future<Uint8List> _fetchChunk(_Session session, int start, int end) async {
    final expected = end - start + 1;
    final out = BytesBuilder(copy: false);
    Object? lastError;

    for (var attempt = 0; attempt < config.maxAttemptsPerChunk; attempt++) {
      if (session.cancelled) throw const _Cancelled();
      if (attempt > 0) {
        // Retrying flat out is how a rate-limited CDN turns into a death
        // spiral: the chunk fails, the stream dies, the player re-opens, the
        // supersede aborts everything in flight, and a fresh burst of
        // connections arrives - which earns a 503 and starts it again. Backing
        // off gives the other end room to recover.
        final backoff = config.retryBackoff * (1 << (attempt - 1));
        await Future<void>.delayed(
          backoff > config.maxRetryBackoff ? config.maxRetryBackoff : backoff,
        );
        if (session.cancelled) throw const _Cancelled();
      }
      final from = start + out.length;
      final uri = _pickMirror(session.upstream, spread: config.spreadAcrossMirrors);
      try {
        await _fetchInto(session, uri, from, end, out);
        _recordSuccess(uri);
        if (out.length == expected) return out.takeBytes();
        lastError = HttpException('short read ${out.length}/$expected');
        config.onLog?.call(
          'chunk $start-$end short at ${out.length}/$expected, resuming',
        );
      } on _Cancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        config.onLog?.call(
          'chunk $start-$end via ${uri.host} failed at '
          '${out.length}/$expected: $e',
        );
        // A mirror that answered WRONGLY is sidelined properly. A dropped or
        // stalled connection says little about the mirror on a route where
        // that happens to all of them - but it must still rotate, or a mirror
        // that is silently dead gets retried until the attempts run out while
        // a healthy backup sits unused. So: brief penalty, long enough to send
        // the next attempt elsewhere, short enough not to sideline it.
        _recordFailure(uri, e);
      }
    }
    throw HttpException('chunk $start-$end failed: $lastError');
  }

  /// Same as [_fetchChunk] but waits its turn first, so the initial window
  /// does not open every connection in the same instant.
  Future<Uint8List> _staggered(
    _Session session,
    int start,
    int end,
    int position,
  ) async {
    await Future<void>.delayed(config.scheduleStagger * position);
    if (session.cancelled) throw const _Cancelled();
    return _fetchChunk(session, start, end);
  }

  /// Appends bytes for [from]-[end] onto [out]. On failure [out] keeps whatever
  /// arrived, so the caller can resume rather than start over.
  Future<void> _fetchInto(
    _Session session,
    Uri uri,
    int from,
    int end,
    BytesBuilder out,
  ) async {
    final want = end - from + 1;
    final req = await _client.getUrl(uri);
    session.upstream.headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$end');

    // Registered before the response is awaited, so a cancellation during the
    // header phase tears the request down instead of waiting out the timeout.
    void abort() => req.abort();
    session.aborts.add(abort);
    if (session.cancelled) {
      session.aborts.remove(abort);
      req.abort();
      throw const _Cancelled();
    }

    final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(config.connectTimeout);
    } finally {
      session.aborts.remove(abort);
    }

    // A node that ignores Range and streams the whole file from zero is worse
    // than useless: it would corrupt the stream and saturate the link.
    if (resp.statusCode != HttpStatus.partialContent) {
      unawaited(resp.drain<void>().catchError((_) {}));
      throw _BadMirror('expected 206, got ${resp.statusCode} from ${uri.host}');
    }
    final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (!_contentRangeMatches(contentRange, from, end)) {
      unawaited(resp.drain<void>().catchError((_) {}));
      throw _BadMirror('bad content-range "$contentRange" from ${uri.host}');
    }

    // Explicit subscription rather than await-for. The body needs a watchdog
    // that fires even when NOTHING arrives - a connection that sends headers
    // and then stalls - and await-for gives no way to cancel from outside.
    //
    // Future.timeout around the whole read would be simpler but is unsafe
    // here: it leaves the subscription alive, still appending to `out` after
    // the caller has resumed from a different offset, silently corrupting the
    // chunk. Awaiting sub.cancel() before returning is what makes resume safe.
    final done = Completer<void>();
    var received = 0;
    Timer? watchdog;

    void arm() {
      watchdog?.cancel();
      watchdog = Timer(config.chunkTimeout, () {
        if (!done.isCompleted) {
          done.completeError(HttpException('body stalled from ${uri.host}'));
        }
      });
    }

    final sub = resp.listen(
      (part) {
        if (done.isCompleted) return;
        if (session.cancelled) {
          done.completeError(const _Cancelled());
          return;
        }
        if (received + part.length > want) {
          done.completeError(_BadMirror('overlong chunk from ${uri.host}'));
          return;
        }
        out.add(part);
        received += part.length;
        arm(); // progress resets the deadline
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    arm();

    try {
      await done.future;
    } finally {
      watchdog?.cancel();
      await sub.cancel();
    }
  }

  /// Picks a mirror for [upstream], skipping hosts that are currently blocked.
  ///
  /// With [spread] false this holds the primary and only moves on when it is
  /// unhealthy; with it true, chunks round-robin across the healthy hosts. If
  /// every host is blocked we use one anyway - a degraded mirror beats
  /// refusing to serve.
  Uri _pickMirror(_Upstream upstream, {required bool spread}) {
    final mirrors = upstream.mirrors;
    final from = spread ? upstream._cursor : 0;
    for (var i = 0; i < mirrors.length; i++) {
      final index = (from + i) % mirrors.length;
      final uri = mirrors[index];
      if (_hostHealth[uri.authority]?.usable ?? true) {
        if (spread) upstream._cursor = (index + 1) % mirrors.length;
        return uri;
      }
    }
    return spread
        ? mirrors[upstream._cursor++ % mirrors.length]
        : mirrors.first;
  }

  void _recordFailure(Uri uri, Object error) {
    // A dropped connection is a property of the route, not the host, and
    // happens to every mirror on a bad path - it must not accumulate into a
    // block. Only unreachable or wrong-answering hosts do.
    if (error is! _BadMirror && error is! SocketException) return;
    (_hostHealth[uri.authority] ??= _HostHealth())
        .fail(config.mirrorPenalty, config.maxHostBlock);
  }

  void _recordSuccess(Uri uri) {
    _hostHealth[uri.authority]?.succeed();
  }
  /// Learns the file size with a one-byte range request. CDNs handle these
  /// more consistently than HEAD, and it doubles as a reachability check.
  Future<int> _resolveLength(_Session session) async {
    final cached = session.upstream.totalLength;
    if (cached != null) return cached;

    Object? lastError;
    for (var attempt = 0; attempt < config.maxAttemptsPerChunk; attempt++) {
      final uri = _pickMirror(session.upstream, spread: config.spreadAcrossMirrors);
      try {
        final req = await _client.getUrl(uri);
        session.upstream.headers.forEach(req.headers.set);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final resp = await req.close().timeout(config.connectTimeout);
        final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
        final mimeType = resp.headers.contentType?.mimeType;
        // Abort the body rather than drain it. Everything needed is in the
        // headers, and draining blocks forever on a node that answers and then
        // stalls without closing - no error, no log, no timeout, because the
        // deadline above covers only the header phase. That hung the request
        // before pumping even started, which the player shows as an endless
        // spinner. Cancelling also frees the connection immediately instead of
        // letting the probe linger against the per-host budget.
        unawaited(
          resp.listen(null, cancelOnError: true).cancel().catchError((_) {}),
        );

        final total = _totalFromContentRange(contentRange);
        if (total == null) {
          // No Content-Range means the node ignored our Range and answered
          // with the whole file. That is a wrong answer, not a flaky route, so
          // it must count against the host - otherwise we ask it again on
          // every attempt and never reach a working mirror.
          throw _BadMirror('no content-range from ${uri.host}');
        }

        _recordSuccess(uri);
        session.upstream.totalLength = total;
        if (mimeType != null && mimeType != 'application/octet-stream') {
          session.upstream.contentType = mimeType;
        }
        return total;
      } catch (e) {
        lastError = e;
        config.onLog?.call('length probe via ${uri.host} failed: $e');
        _recordFailure(uri, e);
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
