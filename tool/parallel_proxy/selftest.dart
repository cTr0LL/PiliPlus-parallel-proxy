// Offline end-to-end test. Spins up a local origin server holding a known
// 20 MiB body, points the proxy at it, and checks that what comes out the other
// side is byte-identical to what went in - across full reads, mid-file ranges,
// small reads, suffix ranges, a deliberately broken mirror, and a client that
// hangs up mid-stream.
//
//   dart run bin/selftest.dart
//
// No network, no bilibili URL, no phone required.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';

const _size = 20 << 20;
final Uint8List _body = _makeBody(_size);

int _passed = 0;
int _failed = 0;

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

  await proxy.stop();
  await origin.close(force: true);
  await badMirror.close(force: true);

  stdout.writeln('');
  stdout.writeln('$_passed passed, $_failed failed');
  exitCode = _failed == 0 ? 0 : 1;
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
