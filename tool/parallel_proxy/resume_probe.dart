// Tests the harness's own resume logic against a server that behaves like the
// CDN did: accepts the range, sends part of it, then drops the connection.
//
//   dart run bin/resume_probe.dart
//
// Without working resume the cold benchmark cannot produce a direct baseline on
// a flaky route, and a failed baseline looks like a proxy win.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '_urls.dart';

const _size = 8 << 20;
final Uint8List _body = _makeBody(_size);

int _passed = 0;
int _failed = 0;

Future<void> main() async {
  // Cuts every response after 1 MiB, so an 8 MiB read needs 7 reconnects.
  final flaky = await _startFlakyOrigin(1 << 20);
  final clean = await _startCleanOrigin();

  final flakyUrl = 'http://127.0.0.1:${flaky.port}/file';
  final cleanUrl = 'http://127.0.0.1:${clean.port}/file';

  final good = await timedGet(cleanUrl, const {}, 0, _size);
  _check('clean: no error', good.error == null, '${good.error}');
  _check('clean: full length', good.bytes.length == _size,
      'got ${good.bytes.length}');
  _check('clean: no reconnects', good.resumes == 0, 'got ${good.resumes}');

  final resumed = await timedGet(flakyUrl, const {}, 0, _size, maxResumes: 16);
  _check('flaky: no error', resumed.error == null, '${resumed.error}');
  _check('flaky: full length', resumed.bytes.length == _size,
      'got ${resumed.bytes.length}');
  _check('flaky: reconnected', resumed.resumes > 0, 'got ${resumed.resumes}');
  _check('flaky: bytes identical', _same(resumed.bytes, 0), 'mismatch');

  // Mid-file offset, because resume must re-request from an absolute position.
  const offset = 3 << 20;
  const span = 4 << 20;
  final mid =
      await timedGet(flakyUrl, const {}, offset, span, maxResumes: 16);
  _check('flaky mid-range: full length', mid.bytes.length == span,
      'got ${mid.bytes.length}');
  _check('flaky mid-range: bytes identical', _same(mid.bytes, offset),
      'mismatch');

  // Give up rather than loop forever when the server never makes progress.
  final capped = await timedGet(flakyUrl, const {}, 0, _size, maxResumes: 2);
  _check('resume cap honoured', capped.error != null, 'expected failure');

  await flaky.close();
  await clean.close(force: true);

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
  final rnd = Random(99);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

/// A well-behaved range server, for the control case.
Future<HttpServer> _startCleanOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final range = _parse(req.headers.value(HttpHeaders.rangeHeader));
    if (range == null) {
      res.statusCode = 416;
      await res.close();
      return;
    }
    final (start, end) = range;
    res.statusCode = 206;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$_size');
    res.contentLength = end - start + 1;
    res.add(Uint8List.sublistView(_body, start, end + 1));
    await res.close();
  });
  return server;
}

/// Announces the full Content-Length, sends [cutAfter] bytes, then destroys the
/// socket. dart:io's HttpServer will not do this - it refuses to detach a
/// socket once headers are out - so the response is written by hand.
///
/// The client sees "Connection closed while receiving data", which is exactly
/// what the real CDN produced on a long single-connection read.
Future<ServerSocket> _startFlakyOrigin(int cutAfter) async {
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
      final range = _parse(header?.trim());
      if (range == null) {
        socket.write('HTTP/1.1 416 Range Not Satisfiable\r\n'
            'Content-Length: 0\r\n\r\n');
        await socket.flush();
        socket.destroy();
        return;
      }

      final (start, end) = range;
      final full = end - start + 1;
      final send = min(cutAfter, full);
      socket.write('HTTP/1.1 206 Partial Content\r\n'
          'Content-Range: bytes $start-$end/$_size\r\n'
          'Content-Length: $full\r\n\r\n');
      socket.add(Uint8List.sublistView(_body, start, start + send));
      await socket.flush();
      socket.destroy(); // short by design
    }, onError: (_) {});
  });
  return server;
}

(int, int)? _parse(String? header) {
  if (header == null) return (0, _size - 1);
  final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header);
  if (m == null) return (0, _size - 1);
  final start = int.parse(m.group(1)!);
  final end =
      m.group(2)!.isEmpty ? _size - 1 : min(int.parse(m.group(2)!), _size - 1);
  if (start >= _size || end < start) return null;
  return (start, end);
}
