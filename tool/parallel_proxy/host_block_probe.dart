// Reproduces the "dead primary keeps getting picked" case seen on the phone.
//
//   dart run tool/parallel_proxy/host_block_probe.dart
//
// The primary is an unroutable address, so connecting TIMES OUT rather than
// being refused - which is how an unreachable mainland mirror behaves. The
// question is whether the proxy learns to skip it after the first failure, or
// keeps paying the connect timeout on every attempt and every chunk.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';

const _size = 8 << 20;

Future<void> main() async {
  final body = Uint8List(_size);
  final rnd = Random(5);
  for (var i = 0; i < _size; i++) {
    body[i] = rnd.nextInt(256);
  }

  final good = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  good.listen((req) async {
    final res = req.response;
    final header = req.headers.value(HttpHeaders.rangeHeader);
    final m = header == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    final start = m == null ? 0 : int.parse(m.group(1)!);
    final end = (m == null || m.group(2)!.isEmpty)
        ? _size - 1
        : min(int.parse(m.group(2)!), _size - 1);
    res.statusCode = 206;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$_size');
    res.contentLength = end - start + 1;
    res.add(Uint8List.sublistView(body, start, end + 1));
    await res.close();
  });

  final picks = <String>[];
  final proxy = ParallelProxy(
    config: ParallelProxyConfig(
      concurrency: 4,
      chunkSize: 512 << 10,
      tcpConnectTimeout: const Duration(milliseconds: 700),
      scheduleStagger: Duration.zero,
      onLog: (m) {
        if (m.contains('failed')) picks.add(m.split(' via ').last.split(' ').first);
        stdout.writeln('  $m');
      },
    ),
  );
  await proxy.start();

  // 10.255.255.1 is unroutable: connections hang until the timeout fires.
  final url = proxy.register(
    url: 'http://10.255.255.1:443/file',
    backupUrls: ['http://127.0.0.1:${good.port}/file'],
  );

  final sw = Stopwatch()..start();
  final client = HttpClient()..autoUncompress = false;
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${(2 << 20) - 1}');
  final resp = await req.close();
  var got = 0;
  await for (final part in resp) {
    got += part.length;
  }
  sw.stop();
  client.close(force: true);

  stdout.writeln('');
  stdout.writeln('status ${resp.statusCode}, $got bytes in '
      '${sw.elapsedMilliseconds}ms');
  final deadHits = picks.where((h) => h.contains('10.255.255.1')).length;
  stdout.writeln('dead-host failures: $deadHits');
  stdout.writeln(deadHits <= 1
      ? 'OK - the dead host was tried once and then skipped'
      : 'BAD - the dead host was tried $deadHits times; blocking is not working');

  await proxy.stop();
  await good.close(force: true);
  exit(0);
}
