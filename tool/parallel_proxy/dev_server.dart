// Desktop harness: run the proxy outside Flutter so you can curl it, point
// mpv/VLC at it, and byte-verify it against a plain sequential download.
//
// Put the URLs in a file, one per line (urls.txt is picked up automatically):
//
//   dart run bin/dev_server.dart --verify           # warm-path comparison
//   dart run bin/dev_server.dart --verify --cold    # cold-path comparison
//   dart run bin/dev_server.dart                    # serve, print local URL
//
// Passing URLs as arguments still works, but signed bilibili URLs contain '&'
// and are painful to quote correctly in cmd.exe - prefer the file.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';

import '_urls.dart';

/// Bytes compared for correctness. Small, because reading them warms the CDN
/// edge for that region and we want the speed test to run on cold bytes.
const _correctnessSize = 4 << 20;

Future<void> main(List<String> args) async {
  final verify = args.contains('--verify');
  final cold = args.contains('--cold');
  final streams = collectStreams(args);
  final urls = streams.video;
  if (urls.isEmpty) return;

  final probeSize = (intFlag(args, '--probe-mib') ?? 64) << 20;
  final concurrency = intFlag(args, '--concurrency') ?? 16;
  final chunkSize = (intFlag(args, '--chunk-kib') ?? 1024) << 10;
  // The audio track is a couple of percent of the video bitrate, so it needs a
  // fraction of the parallelism. Spending 16 connections on it would be pure
  // handshake cost.
  final audioConcurrency = intFlag(args, '--audio-concurrency') ?? 4;

  final proxy = ParallelProxy(
    config: ParallelProxyConfig(
      concurrency: concurrency,
      chunkSize: chunkSize,
    ),
  );
  await proxy.start();

  final local = proxy.register(
    url: urls.first,
    backupUrls: urls.skip(1).toList(),
    headers: bilibiliHeaders,
  );
  final localAudio = streams.hasAudio
      ? proxy.register(
          url: streams.audio.first,
          backupUrls: streams.audio.skip(1).toList(),
          headers: bilibiliHeaders,
          concurrency: audioConcurrency,
        )
      : null;

  if (!verify) {
    stdout
      ..writeln('proxy listening on 127.0.0.1:${proxy.port}')
      ..writeln('video: $local');
    if (localAudio != null) {
      stdout
        ..writeln('audio: $localAudio')
        ..writeln('')
        ..writeln('play:  mpv --audio-file="$localAudio" "$local"');
    } else {
      stdout
        ..writeln('audio: none registered - playback will be SILENT')
        ..writeln('')
        ..writeln('play:  mpv "$local"');
    }
    stdout
      ..writeln('')
      ..writeln('ctrl-c to stop');
    return; // the server keeps the isolate alive
  }

  final chunks = (probeSize / chunkSize).ceil();
  stdout.writeln('$chunks chunks over $concurrency connections '
      '(${(chunks / concurrency).toStringAsFixed(1)} per connection)');
  if (chunks <= concurrency * 2) {
    stdout.writeln('WARNING: too few chunks per connection. Nearly every chunk');
    stdout.writeln('pays a fresh TLS handshake, so this measures connection');
    stdout.writeln('setup rather than throughput. Raise --probe-mib.');
  }
  stdout.writeln('');

  final ok = cold
      ? await _coldRun(urls.first, local, probeSize, proxy)
      : await _warmRun(urls.first, local, probeSize);

  await proxy.stop();
  if (!ok) exitCode = 1;
}

/// Both legs read the same bytes, so the output can be byte-compared. Only
/// meaningful once the file is already cached at the edge - on a cold file the
/// first leg warms the second and the comparison is meaningless.
Future<bool> _warmRun(String directUrl, String localUrl, int probeSize) async {
  stdout.writeln('reading the same first ${probeSize >> 20} MiB both ways');
  stdout.writeln('');

  // Direct first: if the URL itself is dead there is no point blaming the proxy.
  final direct = await timedGet(directUrl, bilibiliHeaders, 0, probeSize);
  if (!_report('direct', direct)) return false;

  final viaProxy = await timedGet(localUrl, const {}, 0, probeSize);
  if (!_report('proxy ', viaProxy)) return false;

  stdout.writeln('');
  if (!_compare(direct.bytes, viaProxy.bytes)) return false;
  _speedup(direct, viaProxy);
  stdout.writeln('');
  stdout.writeln('NOTE: a file you have already fetched is warm at the CDN');
  stdout.writeln('edge. Parallel fetching wins on COLD objects; on a warm one');
  stdout.writeln('the extra handshakes can make it slower. Use --cold on a');
  stdout.writeln('video you have never opened for the number that matters.');
  return true;
}

/// Correctness on a small shared range, then speed on two DISJOINT regions so
/// neither leg warms the CDN edge for the other. Without this the direct leg
/// would pull the exact bytes the proxy leg then reads, and the proxy would be
/// measured against a cache it just filled.
Future<bool> _coldRun(
    String directUrl, String localUrl, int probeSize, ParallelProxy proxy) async {
  final size = await fileSize(directUrl);
  if (size == null) {
    stderr.writeln('could not read file size - cannot lay out cold regions');
    return false;
  }

  // Leave the correctness window at the head, then give each leg its own slab.
  var slab = probeSize;
  final available = size - _correctnessSize;
  if (available < 2 * slab) {
    slab = available ~/ 2;
    stdout.writeln('file is only ${(size / (1 << 20)).toStringAsFixed(0)} MiB; '
        'shrinking each leg to ${(slab / (1 << 20)).toStringAsFixed(0)} MiB');
  }
  if (slab < 8 << 20) {
    stderr.writeln('file too small for a meaningful cold test');
    return false;
  }

  const directStart = _correctnessSize;
  final proxyStart = _correctnessSize + slab;

  stdout.writeln('correctness: first ${_correctnessSize >> 20} MiB, both ways');
  stdout.writeln('(timings here are NOT comparable - the first leg warms the '
      'edge for the second)');
  final a = await timedGet(directUrl, bilibiliHeaders, 0, _correctnessSize);
  if (!_report('direct', a)) return false;
  final b = await timedGet(localUrl, const {}, 0, _correctnessSize);
  if (!_report('proxy ', b)) return false;
  if (!_compare(a.bytes, b.bytes)) return false;
  stdout.writeln('');

  stdout.writeln('speed: disjoint cold regions, ${slab >> 20} MiB each');
  stdout.writeln('  direct reads from ${directStart >> 20} MiB');
  stdout.writeln('  proxy  reads from ${proxyStart >> 20} MiB');
  stdout.writeln('');

  final direct = await timedGet(directUrl, bilibiliHeaders, directStart, slab);
  if (!_report('direct', direct)) return false;
  final viaProxy = await timedGet(localUrl, const {}, proxyStart, slab);
  if (!_report('proxy ', viaProxy)) return false;

  stdout.writeln('');
  _speedup(direct, viaProxy);
  return true;
}

bool _compare(List<int> direct, List<int> viaProxy) {
  if (direct.length != viaProxy.length) {
    stderr.writeln('LENGTH MISMATCH: proxy ${viaProxy.length} '
        'vs direct ${direct.length}');
    return false;
  }
  // Byte-exactness is the whole correctness question: a mirror that silently
  // returns the wrong window shows up here and nowhere else.
  for (var i = 0; i < direct.length; i++) {
    if (direct[i] != viaProxy[i]) {
      stderr.writeln('BYTE MISMATCH at offset $i');
      return false;
    }
  }
  stdout.writeln('bytes identical - OK');
  return true;
}

void _speedup(HarnessResult direct, HarnessResult viaProxy) {
  final d = direct.elapsed.inMilliseconds;
  final p = viaProxy.elapsed.inMilliseconds;
  if (p == 0) return;
  stdout.writeln('speedup: ${(d / p).toStringAsFixed(2)}x');
}

/// Prints one line of timing, or a diagnosis if the response looks wrong.
/// Returns false when the caller should stop.
bool _report(String label, HarnessResult r) {
  if (r.error != null) {
    stderr.writeln('$label : FAILED - ${r.error}');
    return false;
  }
  final mib = r.bytes.length / (1 << 20);
  final secs = r.elapsed.inMilliseconds / 1000;
  final rate = secs > 0 ? mib / secs : 0;
  final resumed = r.resumes > 0 ? '  [${r.resumes} reconnect(s)]' : '';
  stdout.writeln('$label : HTTP ${r.status}  '
      '${mib.toStringAsFixed(1)} MiB in ${secs.toStringAsFixed(2)}s '
      '(${rate.toStringAsFixed(2)} MiB/s)$resumed');

  if (r.status == 200 || r.status == 206) {
    if (r.bytes.length >= 64 << 10) return true;
    stderr.writeln('  -> suspiciously small body; the URL may be truncated');
  } else if (r.status == 403) {
    stderr.writeln('  -> 403: URLs expire after ~2h, or the CDN rejected the '
        'Referer/User-Agent. Re-grab them from the browser.');
  } else if (r.status == 404) {
    stderr.writeln('  -> 404: URL is wrong or truncated. If you pasted on the '
        'command line, a & may have cut it short - use urls.txt instead.');
  }

  // Short bodies are almost always an error page worth reading.
  if (r.bytes.length < 4096 && r.bytes.isNotEmpty) {
    final text = utf8.decode(r.bytes, allowMalformed: true);
    final preview = text.length > 400 ? '${text.substring(0, 400)}...' : text;
    stderr.writeln('  -> body: $preview');
  }
  return false;
}
