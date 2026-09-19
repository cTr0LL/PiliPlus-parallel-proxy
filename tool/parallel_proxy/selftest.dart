// Offline end-to-end test. Spins up a local origin server holding a known
// 20 MiB body, points the proxy at it, and checks that what comes out the other
// side is byte-identical to what went in - across full reads, mid-file ranges,
// small reads, suffix ranges, a deliberately broken mirror, and a client that
// hangs up mid-stream.
//
//   dart run bin/selftest.dart
//
// No network, no bilibili URL, no phone required.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';

const _size = 20 << 20;
final Uint8List _body = _makeBody(_size);

int _passed = 0;
int _failed = 0;
int _openUpstreamRequests = 0;
int _intermittentRequests = 0;

Future<void> main() async {
  final origin = await _startOrigin(honourRange: true);
  // Ignores Range and always returns 200 with the whole file - exactly the
  // failure mode chunk validation exists to catch.
  final badMirror = await _startOrigin(honourRange: false);

  final goodUrl = 'http://127.0.0.1:${origin.port}/file';
  final badUrl = 'http://127.0.0.1:${badMirror.port}/file';

  final proxy = ParallelProxy(
    config: const ParallelProxyConfig(
      concurrency: 6,
      chunkSize: 1 << 20,
      minParallelSize: 256 << 10,
    ),
  );
  await proxy.start();

  // 1. Whole file, no Range header at all.
  final whole = proxy.register(url: goodUrl);
  final r1 = await _get(whole);
  _check('full read: status 200', r1.status == 200, 'got ${r1.status}');
  _check('full read: length', r1.bytes.length == _size,
      'got ${r1.bytes.length} want $_size');
  _check('full read: bytes identical', _same(r1.bytes, 0), 'mismatch');

  // 2. A mid-file range spanning several chunks - the normal playback case.
  const start = 3 << 20;
  const end = (11 << 20) + 12345;
  final r2 = await _get(whole, range: 'bytes=$start-$end');
  _check('mid range: status 206', r2.status == 206, 'got ${r2.status}');
  _check('mid range: length', r2.bytes.length == end - start + 1,
      'got ${r2.bytes.length}');
  _check('mid range: bytes identical', _same(r2.bytes, start), 'mismatch');

  // 3. Below minParallelSize, so it takes the single-connection path that
  //    FFmpeg's header probe hits.
  final r3 = await _get(whole, range: 'bytes=0-65535');
  _check('small read: status 206', r3.status == 206, 'got ${r3.status}');
  _check('small read: bytes identical',
      r3.bytes.length == 65536 && _same(r3.bytes, 0), 'mismatch');

  // 4. Suffix form - FFmpeg uses this hunting for a trailing moov atom.
  final r4 = await _get(whole, range: 'bytes=-65536');
  _check('suffix range: status 206', r4.status == 206, 'got ${r4.status}');
  _check('suffix range: bytes identical',
      r4.bytes.length == 65536 && _same(r4.bytes, _size - 65536), 'mismatch');

  // 5. HEAD should report size without a body.
  final r5 = await _get(whole, method: 'HEAD');
  _check('HEAD: status 200', r5.status == 200, 'got ${r5.status}');
  _check('HEAD: empty body', r5.bytes.isEmpty, 'got ${r5.bytes.length} bytes');

  // 6. Unsatisfiable range.
  final r6 = await _get(whole, range: 'bytes=${_size + 10}-');
  _check('bad range: status 416', r6.status == 416, 'got ${r6.status}');

  // 7. Broken mirror listed first: every chunk it serves must be rejected and
  //    retried against the good one, with the output still byte-exact.
  final mixed = proxy.register(url: badUrl, backupUrls: [goodUrl]);
  final r7 = await _get(mixed, range: 'bytes=0-${(4 << 20) - 1}');
  _check('bad mirror: status 206', r7.status == 206, 'got ${r7.status}');
  _check('bad mirror: bytes identical',
      r7.bytes.length == (4 << 20) && _same(r7.bytes, 0), 'mismatch');

  // 8. Client hangs up mid-stream (what a seek looks like). The proxy must not
  //    die, and must still serve the next request correctly.
  await _hangUpEarly(whole);
  final r8 = await _get(whole, range: 'bytes=${1 << 20}-${(3 << 20) - 1}');
  _check('after hangup: still serving', r8.status == 206, 'got ${r8.status}');
  _check('after hangup: bytes identical', _same(r8.bytes, 1 << 20), 'mismatch');

  // 9. Per-registration concurrency, as used for a DASH audio track: it must
  //    still reassemble correctly with a different in-flight budget.
  final lowConcurrency = proxy.register(url: goodUrl, concurrency: 2);
  final r9 = await _get(lowConcurrency, range: 'bytes=0-${(6 << 20) - 1}');
  _check('low concurrency: status 206', r9.status == 206, 'got ${r9.status}');
  _check('low concurrency: bytes identical',
      r9.bytes.length == (6 << 20) && _same(r9.bytes, 0), 'mismatch');

  // 10. Two registrations served at once, the way video + audio play together.
  final second = proxy.register(url: goodUrl, concurrency: 4);
  final both = await Future.wait([
    _get(whole, range: 'bytes=0-${(5 << 20) - 1}'),
    _get(second, range: 'bytes=${5 << 20}-${(10 << 20) - 1}'),
  ]);
  _check('concurrent streams: both 206',
      both[0].status == 206 && both[1].status == 206,
      '${both[0].status}/${both[1].status}');
  _check('concurrent streams: bytes identical',
      _same(both[0].bytes, 0) && _same(both[1].bytes, 5 << 20), 'mismatch');

  // 11. Unregistering must stop a stream that is still being served.
  //     A player can abandon a stream without closing the socket - mpv does
  //     this when you leave a video - so res.done never errors and the pump
  //     sits blocked on flush with chunk fetches still consuming the per-host
  //     connection budget. Enough of those and a NEW video cannot get
  //     connections at all.
  final abandoned = proxy.register(url: goodUrl);
  final stalled = await _openWithoutReading(abandoned, _size);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final beforeCancel = _openUpstreamRequests;
  proxy.unregister(abandoned);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  _check('unregister cancels a live session',
      _openUpstreamRequests < beforeCancel || beforeCancel == 0,
      'open upstream requests $beforeCancel -> $_openUpstreamRequests');
  stalled.destroy();

  // 12. A second request on the SAME registration must supersede the first.
  //     mpv re-opens and seeks constantly without closing the old connection,
  //     so sessions would otherwise pile up on one stream - six seeks meant six
  //     live pumps, each holding the full concurrency budget.
  final seeky = proxy.register(url: goodUrl);
  final first = await _openWithoutReading(seeky, _size);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final beforeSupersede = _openUpstreamRequests;
  final second2 = await _openWithoutReading(seeky, _size);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  _check(
      'second request supersedes the first',
      _openUpstreamRequests <= beforeSupersede,
      'open upstream requests $beforeSupersede -> $_openUpstreamRequests '
      '(should not have doubled)');
  first.destroy();
  second2.destroy();

  // 13. An origin that cuts every response mid-body, the way the real CDN does
  //     on a long-haul route. The proxy must resume from where it stopped
  //     rather than restart the chunk, and still produce exact bytes. Without
  //     resume, each cut spends a whole attempt re-fetching bytes already in
  //     hand, the attempts run out, and the ordered stream dies - which the
  //     player reports only as a failure to open.
  final choppy = await _startChoppyOrigin(256 << 10);
  final choppyUrl = proxy.register(
    url: 'http://127.0.0.1:${choppy.port}/file',
    concurrency: 4,
  );
  final r13 = await _get(choppyUrl, range: 'bytes=0-${(3 << 20) - 1}');
  _check('choppy origin: status 206', r13.status == 206, 'got ${r13.status}');
  _check('choppy origin: full length', r13.bytes.length == (3 << 20),
      'got ${r13.bytes.length} of ${3 << 20}');
  _check('choppy origin: bytes identical', _same(r13.bytes, 0), 'mismatch');
  await choppy.close();

  // 14. A mirror that sends headers and then goes silent forever. The body
  //     watchdog must fire even though no data ever arrives - an elapsed
  //     check inside a read loop cannot, because the loop never iterates.
  //     That hung the player indefinitely with no error at all. The stalled
  //     mirror must also rotate, or a healthy backup never gets used.
  //
  //     Its own proxy, with short timeouts, so the test does not sit through
  //     the production idle timeout.
  final mute = await _startMuteOrigin();
  final impatient = ParallelProxy(
    config: const ParallelProxyConfig(
      concurrency: 2,
      chunkSize: 1 << 20,
      chunkTimeout: Duration(milliseconds: 600),
      transientPenalty: Duration(seconds: 5),
    ),
  );
  await impatient.start();
  final muteUrl = impatient.register(
    url: 'http://127.0.0.1:${mute.port}/file',
    backupUrls: [goodUrl],
  );
  final muteWatch = Stopwatch()..start();
  final r14 = await _get(muteUrl, range: 'bytes=0-${(2 << 20) - 1}').timeout(
    const Duration(seconds: 20),
    onTimeout: () => _Response(0, const []),
  );
  muteWatch.stop();
  _check('mute mirror: does not hang', r14.status != 0,
      'still stuck after ${muteWatch.elapsed.inSeconds}s');
  _check('mute mirror: rotates to the healthy backup',
      r14.bytes.length == (2 << 20) && _same(r14.bytes, 0),
      'got ${r14.bytes.length} of ${2 << 20} bytes');
  await impatient.stop();
  await mute.close();

  // 15. Slow start: a cold object must not be met with the full window of
  //     parallel range requests. N parallel requests against an object that
  //     is not cached at the edge means N concurrent origin pulls, which is
  //     what earns a 503 - and is why a video could fail on first open then
  //     play instantly on retry, the failed attempt having warmed the edge.
  final coldOrigin = await _startOrigin(honourRange: true);
  final ramped = ParallelProxy(
    config: const ParallelProxyConfig(
      concurrency: 8,
      initialConcurrency: 2,
      chunkSize: 512 << 10,
      scheduleStagger: Duration.zero,
    ),
  );
  await ramped.start();
  final coldUrl = ramped.register(
    url: 'http://127.0.0.1:${coldOrigin.port}/file',
  );
  final probe = _openWithoutReading(coldUrl, 8 << 20);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final openedAtOnce = _openUpstreamRequests;
  _check('slow start: opening window is narrow',
      openedAtOnce <= 3,
      'opened $openedAtOnce at once; want <= 3 (initial window + length probe)');
  (await probe).destroy();
  await ramped.stop();
  await coldOrigin.close(force: true);

  // 16. Host health is shared across registrations. An unreachable host must
  //     be learned once, not re-learned per video: otherwise every playback
  //     starts by paying a fresh connect timeout on a mirror already known to
  //     be dead. This is the difference between a 4s tax once and a 4s tax on
  //     every single video.
  final shared = ParallelProxy(
    config: const ParallelProxyConfig(
      concurrency: 2,
      chunkSize: 512 << 10,
      tcpConnectTimeout: Duration(milliseconds: 400),
      scheduleStagger: Duration.zero,
    ),
  );
  await shared.start();

  // Port 1 on loopback refuses instantly, standing in for an unreachable host.
  const deadHost = 'http://127.0.0.1:1/file';
  final firstVideo = shared.register(url: deadHost, backupUrls: [goodUrl]);
  final v1 = await _get(firstVideo, range: 'bytes=0-${(1 << 20) - 1}');
  _check('shared health: first video still served', v1.status == 206,
      'got ${v1.status}');

  // A DIFFERENT registration, i.e. the next video, with the same dead primary.
  final secondVideo = shared.register(url: deadHost, backupUrls: [goodUrl]);
  final watch = Stopwatch()..start();
  final v2 = await _get(secondVideo, range: 'bytes=0-${(1 << 20) - 1}');
  watch.stop();
  _check('shared health: second video also served', v2.status == 206,
      'got ${v2.status}');
  _check('shared health: dead host not retried for the next video',
      watch.elapsedMilliseconds < 400,
      'took ${watch.elapsedMilliseconds}ms; a re-learned host would pay the connect timeout again');
  await shared.stop();

  // 17. An INTERMITTENT host - one that answers occasionally - must stay
  //     blocked once it has earned a block. Concurrent chunks are still in
  //     flight when the block is set, so one of them succeeding afterwards
  //     must not lift it: otherwise the host unblocks itself instantly, gets
  //     picked again, and costs another timeout, over and over. This is what
  //     an unreachable-but-not-quite mainland mirror actually looks like.
  final flaky = await _startIntermittentOrigin(failEvery: 3);
  final picky = ParallelProxy(
    config: const ParallelProxyConfig(
      concurrency: 4,
      chunkSize: 512 << 10,
      scheduleStagger: Duration.zero,
      mirrorPenalty: Duration(seconds: 30),
    ),
  );
  await picky.start();
  final flakyUrl = picky.register(
    url: 'http://127.0.0.1:${flaky.port}/file',
    backupUrls: [goodUrl],
  );
  final r17 = await _get(flakyUrl, range: 'bytes=0-${(4 << 20) - 1}');
  final flakyHits = _intermittentRequests;
  _check('intermittent host: still served correctly',
      r17.bytes.length == (4 << 20) && _same(r17.bytes, 0),
      'got ${r17.bytes.length} bytes');
  _check('intermittent host: stops being retried once blocked',
      flakyHits <= 4,
      'hit the flaky host \$flakyHits times; a self-clearing block would keep returning to it');
  await picky.stop();
  await flaky.close(force: true);

  await proxy.stop();
  await origin.close(force: true);
  await badMirror.close(force: true);

  stdout.writeln('');
  stdout.writeln('$_passed passed, $_failed failed');
  // exit() rather than falling off the end: the deliberately misbehaving
  // origins hold sockets open, and a fire-and-forget drain keeps the event
  // loop alive, so the isolate would never terminate on its own.
  exit(_failed == 0 ? 0 : 1);
}

void _check(String name, bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $name  ($detail)');
  }
}

bool _same(List<int> got, int originOffset) {
  for (var i = 0; i < got.length; i++) {
    if (got[i] != _body[originOffset + i]) return false;
  }
  return true;
}

Uint8List _makeBody(int size) {
  final rnd = Random(1234);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

class _Response {
  _Response(this.status, this.bytes);
  final int status;
  final List<int> bytes;
}

Future<_Response> _get(String url, {String? range, String method = 'GET'}) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final uri = Uri.parse(url);
    final req = method == 'HEAD'
        ? await client.headUrl(uri)
        : await client.getUrl(uri);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final resp = await req.close();
    final out = BytesBuilder(copy: false);
    await for (final part in resp) {
      out.add(part);
    }
    return _Response(resp.statusCode, out.takeBytes());
  } finally {
    client.close(force: true);
  }
}

/// Accepts the request, answers with valid 206 headers, then never sends a
/// single body byte and never closes. Models a dead-but-open connection.
Future<ServerSocket> _startMuteOrigin() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.listen((_) {
      socket.write('HTTP/1.1 206 Partial Content\r\n'
          'Content-Range: bytes 0-${_size - 1}/$_size\r\n'
          'Content-Length: $_size\r\n\r\n');
      socket.flush();
      // and then nothing, forever
    }, onError: (_) {});
  });
  return server;
}

/// Answers correctly only occasionally: every [failEvery]-th request wins,
/// the rest are dropped without a response. Models a mirror that is mostly
/// unreachable but not entirely.
Future<HttpServer> _startIntermittentOrigin({required int failEvery}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    _intermittentRequests++;
    if (_intermittentRequests % failEvery != 0) {
      await req.response.close().catchError((_) {});
      return;
    }
    final res = req.response;
    final header = req.headers.value(HttpHeaders.rangeHeader);
    final m = header == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)\$').firstMatch(header.trim());
    final start = m == null ? 0 : int.parse(m.group(1)!);
    final end = (m == null || m.group(2)!.isEmpty)
        ? _size - 1
        : min(int.parse(m.group(2)!), _size - 1);
    res.statusCode = 206;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes \$start-\$end/\$_size');
    res.contentLength = end - start + 1;
    res.add(Uint8List.sublistView(_body, start, end + 1));
    await res.close();
  });
  return server;
}

/// Serves correct ranges but destroys the socket after [cutAfter] body bytes,
/// every time. Written on a raw socket because dart:io HttpServer refuses to
/// detach one once headers are out.
Future<ServerSocket> _startChoppyOrigin(int cutAfter) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final request = StringBuffer();
    late StreamSubscription<Uint8List> sub;
    sub = socket.listen((data) async {
      request.write(String.fromCharCodes(data));
      if (!request.toString().contains('\r\n\r\n')) return;
      await sub.cancel();

      final header = RegExp(r'^range:\s*(.+)$',
              multiLine: true, caseSensitive: false)
          .firstMatch(request.toString())
          ?.group(1);
      final m = header == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
      final start = m == null ? 0 : int.parse(m.group(1)!);
      final end = (m == null || m.group(2)!.isEmpty)
          ? _size - 1
          : min(int.parse(m.group(2)!), _size - 1);
      if (start >= _size || end < start) {
        socket.write('HTTP/1.1 416 Range Not Satisfiable\r\n'
            'Content-Length: 0\r\n\r\n');
        await socket.flush();
        socket.destroy();
        return;
      }

      final full = end - start + 1;
      final send = min(cutAfter, full);
      socket
        ..write('HTTP/1.1 206 Partial Content\r\n'
            'Content-Range: bytes $start-$end/$_size\r\n'
            'Content-Length: $full\r\n\r\n')
        ..add(Uint8List.sublistView(_body, start, start + send));
      await socket.flush();
      socket.destroy(); // short by design, every single time
    }, onError: (_) {});
  });
  return server;
}

/// Opens a request and never reads the body, holding the connection open the
/// way a player does when it walks away from a stream without closing it.
Future<Socket> _openWithoutReading(String url, int size) async {
  final uri = Uri.parse(url);
  final socket = await Socket.connect(uri.host, uri.port);
  socket.write('GET ${uri.path} HTTP/1.1\r\n'
      'Host: ${uri.host}:${uri.port}\r\n'
      'Range: bytes=0-${size - 1}\r\n\r\n');
  await socket.flush();
  socket.listen((_) {}, onError: (_) {}, cancelOnError: true).pause();
  return socket;
}

/// Opens a raw socket, asks for a large range, reads a little, then slams the
/// connection shut without draining it.
Future<void> _hangUpEarly(String url) async {
  final uri = Uri.parse(url);
  final socket = await Socket.connect(uri.host, uri.port);
  socket.write('GET ${uri.path} HTTP/1.1\r\n'
      'Host: ${uri.host}:${uri.port}\r\n'
      'Range: bytes=0-${_size - 1}\r\n'
      'Connection: close\r\n\r\n');
  await socket.flush();
  var seen = 0;
  await for (final chunk in socket) {
    seen += chunk.length;
    if (seen > 32 * 1024) break;
  }
  socket.destroy();
  // Give the proxy a moment to notice and unwind its in-flight fetches.
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// A minimal static origin. With [honourRange] false it ignores Range entirely
/// and returns 200 plus the whole body.
Future<HttpServer> _startOrigin({required bool honourRange}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    _openUpstreamRequests++;
    req.response.done.whenComplete(() => _openUpstreamRequests--);
    final res = req.response;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

    if (!honourRange || rangeHeader == null) {
      res.statusCode = 200;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.contentLength = _size;
      res.add(_body);
      await res.close();
      return;
    }

    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
    if (m == null) {
      res.statusCode = 416;
      await res.close();
      return;
    }
    final rawStart = m.group(1)!;
    final rawEnd = m.group(2)!;
    final int s;
    final int e;
    if (rawStart.isEmpty) {
      s = max(0, _size - int.parse(rawEnd));
      e = _size - 1;
    } else {
      s = int.parse(rawStart);
      e = rawEnd.isEmpty ? _size - 1 : min(int.parse(rawEnd), _size - 1);
    }
    if (s >= _size || e < s) {
      res.statusCode = 416;
      await res.close();
      return;
    }
    res.statusCode = 206;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/$_size');
    res.contentLength = e - s + 1;
    res.add(Uint8List.sublistView(_body, s, e + 1));
    await res.close();
  });
  return server;
}
