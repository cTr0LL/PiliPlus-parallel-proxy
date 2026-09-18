// Measures where the ceiling actually is, with no proxy involved.
//
// Answers two questions the --verify run cannot separate:
//   1. Are the mirrors different speeds? (round-robin across an uneven set
//      averages you toward the slow one)
//   2. Does opening more connections raise AGGREGATE throughput at all? If it
//      does not, the route is the bottleneck and this whole technique cannot
//      help on this connection.
//
//   dart run bin/bench.dart
//   dart run bin/bench.dart --seconds=5
//
// Each measurement runs for a fixed window and reports bytes actually moved,
// so total runtime is predictable regardless of how slow the link is.
import 'dart:async';
import 'dart:io';

import '_urls.dart';

late Duration _window;

Future<void> main(List<String> args) async {
  final urls = collectUrls(args);
  if (urls.isEmpty) return;
  _window = Duration(seconds: intFlag(args, '--seconds') ?? 8);

  final size = await fileSize(urls.first);
  if (size == null) {
    stderr.writeln('could not read file size from ${Uri.parse(urls.first).host}');
    exitCode = 1;
    return;
  }
  stdout.writeln('file size: ${(size / (1 << 20)).toStringAsFixed(1)} MiB');
  stdout.writeln('each measurement runs for ${_window.inSeconds}s');
  stdout.writeln('');

  // 1. One connection per mirror, so an uneven set is visible.
  stdout.writeln('per-mirror, 1 connection:');
  final perMirror = <String, double>{};
  for (final u in urls) {
    final host = Uri.parse(u).host;
    final rate = await _measure([u], 1, size);
    perMirror[u] = rate;
    stdout.writeln('  ${host.padRight(40)} ${_fmt(rate)}');
  }
  stdout.writeln('');

  // 2. Scale connections on the single best mirror. This is the load-bearing
  //    measurement: if the curve is flat, the link is saturated at 1 connection
  //    and nothing downstream of here can help.
  final best = perMirror.entries.reduce((a, b) => a.value >= b.value ? a : b);
  stdout.writeln('${Uri.parse(best.key).host}, scaling connections:');
  final scaled = <int, double>{};
  for (final n in const [1, 2, 4, 8, 16, 24, 32]) {
    final rate = await _measure([best.key], n, size);
    scaled[n] = rate;
    stdout.writeln('  ${n.toString().padLeft(2)} conn   ${_fmt(rate)}');
  }
  stdout.writeln('');

  // 3. All mirrors at once, in case the per-host cap is the binding one.
  double? combined;
  if (urls.length > 1) {
    combined = await _measure(urls, 8, size);
    stdout.writeln('all mirrors, 8 conn spread across them: ${_fmt(combined)}');
    stdout.writeln('');
  }

  _verdict(scaled, perMirror, combined);
}

void _verdict(
    Map<int, double> scaled, Map<String, double> perMirror, double? combined) {
  final one = scaled[1] ?? 0;
  final peak = scaled.values.fold<double>(0, (a, b) => a > b ? a : b);
  final gain = one > 0 ? peak / one : 0;

  stdout.writeln('--- verdict ---');
  stdout.writeln('parallel gain on best mirror: ${gain.toStringAsFixed(2)}x');

  if (gain < 1.3) {
    stdout.writeln('The link saturates at one connection. Per-connection');
    stdout.writeln('throttling is NOT your bottleneck, so a multi-threaded');
    stdout.writeln('fetcher cannot help here. Stop.');
  } else {
    final bestN = scaled.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final maxN = scaled.keys.reduce((a, b) => a > b ? a : b);
    stdout.writeln('Parallelism helps, peaking around $bestN connections.');
    if (bestN == maxN) {
      // Never recommend the edge of the range as if it were a plateau.
      stdout.writeln('That is the highest value tested, so the curve has not');
      stdout.writeln('flattened yet - re-run with a longer ladder to find the');
      stdout.writeln('real knee before settling on a number.');
    }
    stdout.writeln('Set ParallelProxyConfig.concurrency to $bestN.');
  }

  if (perMirror.length > 1) {
    final rates = perMirror.values.toList()..sort();
    final spread = rates.first > 0 ? rates.last / rates.first : 0;

    // The combined run is the direct evidence; the per-mirror spread only
    // explains why spreading hurt.
    if (combined != null && combined > peak * 1.15) {
      stdout.writeln('');
      stdout.writeln('All mirrors together beat the best one alone: the cap is');
      stdout.writeln('per-host. Set spreadAcrossMirrors: true.');
    } else if (combined != null) {
      stdout.writeln('');
      stdout.writeln('Spreading across mirrors does not beat the best mirror');
      stdout.writeln('alone, so the cap is per-connection, not per-host.');
      stdout.writeln('Keep spreadAcrossMirrors: false (mirrors = failover).');
      if (spread > 1.2) {
        stdout.writeln('The mirrors differ by ${spread.toStringAsFixed(1)}x, so '
            'spreading would');
        stdout.writeln('drag throughput toward the slower one for no gain.');
      }
    }
  }
}

/// Runs [connections] readers for the measurement window and returns MiB/s.
/// Each reader starts at a different offset so the CDN cannot serve them all
/// from one hot cache entry.
Future<double> _measure(List<String> urls, int connections, int size) async {
  final client = HttpClient()
    ..maxConnectionsPerHost = connections * 2
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 10);

  var total = 0;
  var stop = false;
  final timer = Timer(_window, () => stop = true);
  final sw = Stopwatch()..start();

  Future<void> reader(int i) async {
    final url = urls[i % urls.length];
    final offset = ((size ~/ connections) * i).clamp(0, size - 1);
    try {
      final req = await client.getUrl(Uri.parse(url));
      bilibiliHeaders.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${size - 1}');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        stderr.writeln('  (HTTP ${resp.statusCode} from '
            '${Uri.parse(url).host})');
        return;
      }
      await for (final part in resp) {
        total += part.length;
        if (stop) break; // cancels the subscription, closing the socket
      }
    } catch (_) {
      // A dead connection just contributes no bytes.
    }
  }

  await Future.wait(List.generate(connections, reader));
  sw.stop();
  timer.cancel();
  client.close(force: true);

  final secs = sw.elapsedMilliseconds / 1000;
  return secs > 0 ? (total / (1 << 20)) / secs : 0;
}

String _fmt(double mibPerSec) => '${mibPerSec.toStringAsFixed(2)} MiB/s';
