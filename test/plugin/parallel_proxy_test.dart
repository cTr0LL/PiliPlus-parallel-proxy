import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/parallel_proxy/proxy_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the real ProxyService against a local origin, with no Android or
/// Windows toolchain involved. Covers the wiring the standalone package cannot:
/// the headers PiliPlus actually sends, the per-track concurrency split, the
/// fallback paths, and registration eviction.
///
/// Runs on a stock Flutter SDK because ProxyService takes the chosen CDN url as
/// an argument instead of importing VideoUtils, which would drag in Pref and
/// from there the whole widget layer.
void main() {
  const size = 6 << 20;
  final body = _makeBody(size);

  setUp(() async {
    ProxyService.enabled = true;
    ProxyService.videoConcurrency = 8;
    ProxyService.audioConcurrency = 2;
    await ProxyService.start();
  });

  tearDown(() async {
    await ProxyService.stop();
    ProxyService.enabled = true;
  });

  test('accelerate returns a loopback url backed by the origin', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    final local = ProxyService.accelerate(origin.url, [origin.url]);

    expect(local, startsWith('http://127.0.0.1:'));
    expect(local, isNot(origin.url));

    final got = await _get(local);
    expect(got.length, size);
    expect(_same(got, body), isTrue, reason: 'bytes must round-trip exactly');
  });

  test('sends the Referer and User-Agent PiliPlus uses for playback', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    await _get(ProxyService.accelerate(origin.url, [origin.url]));

    // The CDN 403s without these, and they must match what pl_player sets via
    // setMediaHeader, not merely be plausible.
    expect(origin.seenReferers, contains(HttpString.baseUrl));
    expect(origin.seenUserAgents, contains(BrowserUa.pc));
  });

  test('audio gets fewer connections than video', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    await _get(ProxyService.accelerate(origin.url, [origin.url]));
    final videoPeak = origin.peakConcurrent;

    origin.resetPeak();
    await _get(
      ProxyService.accelerate(origin.url, [origin.url], isAudio: true),
    );
    final audioPeak = origin.peakConcurrent;

    expect(
      videoPeak,
      greaterThan(audioPeak),
      reason:
          'audio carries ~2% of the bitrate and should not spend the '
          'video budget on TLS handshakes',
    );
    expect(audioPeak, lessThanOrEqualTo(ProxyService.audioConcurrency));
  });

  test('falls back to the direct url when disabled', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    ProxyService.enabled = false;
    final url = ProxyService.accelerate(origin.url, [origin.url]);

    expect(url, origin.url, reason: 'must be the url passed in, untouched');
  });

  test('falls back to the direct url when the proxy is not running', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    await ProxyService.stop();
    final url = ProxyService.accelerate(origin.url, [origin.url]);

    expect(url, origin.url);
  });

  test('uses later mirrors when the primary rejects the request', () async {
    // A node that 403s everything, listed first, with a good one behind it.
    final dead = await _Origin.start(body, alwaysForbid: true);
    final good = await _Origin.start(body);
    addTearDown(dead.close);
    addTearDown(good.close);

    final local = ProxyService.accelerate(dead.url, [dead.url, good.url]);
    final got = await _get(local);

    expect(got.length, size);
    expect(_same(got, body), isTrue);
    expect(
      good.requestCount,
      greaterThan(0),
      reason: 'the backup mirror must actually have been used',
    );
  });

  test('old registrations are evicted so tokens do not accumulate', () async {
    final origin = await _Origin.start(body);
    addTearDown(origin.close);

    // More than the retained window; the first must stop resolving.
    final first = ProxyService.accelerate(origin.url, [origin.url]);
    for (var i = 0; i < 8; i++) {
      ProxyService.accelerate(origin.url, [origin.url]);
    }

    final status = await _statusOf(first);
    expect(status, 404, reason: 'evicted registrations should not linger');
  });
}

// ---------------------------------------------------------------------------

class _Origin {
  _Origin(this._server, this._body, this._alwaysForbid);

  final HttpServer _server;
  final Uint8List _body;
  final bool _alwaysForbid;

  final seenReferers = <String>{};
  final seenUserAgents = <String>{};
  int requestCount = 0;
  int _concurrent = 0;
  int peakConcurrent = 0;

  String get url => 'http://127.0.0.1:${_server.port}/file';

  void resetPeak() => peakConcurrent = 0;

  Future<void> close() => _server.close(force: true);

  static Future<_Origin> start(
    Uint8List body, {
    bool alwaysForbid = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(server, body, alwaysForbid);
    server.listen(origin._handle);
    return origin;
  }

  Future<void> _handle(HttpRequest req) async {
    requestCount++;
    _concurrent++;
    peakConcurrent = max(peakConcurrent, _concurrent);

    final referer = req.headers.value(HttpHeaders.refererHeader);
    if (referer != null) seenReferers.add(referer);
    final ua = req.headers.value(HttpHeaders.userAgentHeader);
    if (ua != null) seenUserAgents.add(ua);

    final res = req.response;
    try {
      if (_alwaysForbid) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }

      final header = req.headers.value(HttpHeaders.rangeHeader);
      final m = header == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
      final start = m == null ? 0 : int.parse(m.group(1)!);
      final end = (m == null || m.group(2)!.isEmpty)
          ? _body.length - 1
          : min(int.parse(m.group(2)!), _body.length - 1);

      if (start >= _body.length || end < start) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }

      // Enough of a pause that parallel requests actually overlap, so
      // peakConcurrent measures the fetcher rather than scheduling luck.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      res.statusCode = m == null ? HttpStatus.ok : HttpStatus.partialContent;
      if (m != null) {
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${_body.length}',
        );
      }
      res
        ..contentLength = end - start + 1
        ..add(Uint8List.sublistView(_body, start, end + 1));
      await res.close();
    } finally {
      _concurrent--;
    }
  }
}

Future<List<int>> _get(String url) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final resp = await (await client.getUrl(Uri.parse(url))).close();
    final out = BytesBuilder(copy: false);
    await for (final part in resp) {
      out.add(part);
    }
    return out.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<int> _statusOf(String url) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final resp = await (await client.getUrl(Uri.parse(url))).close();
    await resp.drain<void>().catchError((_) {});
    return resp.statusCode;
  } finally {
    client.close(force: true);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _makeBody(int size) {
  final rnd = Random(7);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}
