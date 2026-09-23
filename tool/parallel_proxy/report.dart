// Summarises the telemetry pulled off the phone.
//
//   dart run tool/parallel_proxy/report.dart sessions.jsonl
//
// Answers the question the raw lines do not: over this period, was playback
// slow, was it failing, and which hosts were responsible.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/parallel_proxy/report.dart '
        '<sessions.jsonl> [more.jsonl ...]');
    exitCode = 64;
    return;
  }

  final records = <Map<String, Object?>>[];
  for (final path in args) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('missing: $path');
      continue;
    }
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        records.add(jsonDecode(line) as Map<String, Object?>);
      } catch (_) {
        // A truncated last line is normal if the app was killed mid-write.
      }
    }
  }
  if (records.isEmpty) {
    stdout.writeln('no records');
    return;
  }

  records.sort((a, b) => '${a['t']}'.compareTo('${b['t']}'));
  stdout
    ..writeln('${records.length} requests, '
        '${records.first['t']} .. ${records.last['t']}')
    ..writeln('');

  // Only video requests that actually served bytes say anything about speed.
  final video = records.where((r) => r['kind'] == 'video').toList();
  final served = video
      .where((r) => (r['bytes'] as num? ?? 0) > 0 && r['ttfb_ms'] != null)
      .toList();

  stdout.writeln('--- startup latency (video, time to first byte) ---');
  if (served.isEmpty) {
    stdout.writeln('  nothing served');
  } else {
    final ttfb = served.map((r) => (r['ttfb_ms'] as num).toInt()).toList()
      ..sort();
    stdout
      ..writeln('  median ${_pct(ttfb, 50)} ms   '
          'p90 ${_pct(ttfb, 90)} ms   worst ${ttfb.last} ms')
      ..writeln('  over 3s: ${ttfb.where((v) => v > 3000).length} of '
          '${ttfb.length}');
  }

  stdout.writeln('');
  stdout.writeln('--- throughput (video, kbit/s) ---');
  final kbps = served
      .where((r) => r['kbps'] != null)
      .map((r) => (r['kbps'] as num).toInt())
      .toList()
    ..sort();
  if (kbps.isEmpty) {
    stdout.writeln('  no samples');
  } else {
    stdout.writeln('  median ${_pct(kbps, 50)}   p10 ${_pct(kbps, 10)}   '
        'best ${kbps.last}');
  }

  stdout.writeln('');
  stdout.writeln('--- outcomes ---');
  final outcomes = <String, int>{};
  for (final r in records) {
    final key = '${r['outcome']}';
    outcomes[key] = (outcomes[key] ?? 0) + 1;
  }
  // "superseded" is normal - it is what a seek looks like - so it is not a
  // fault. "failed" with no bytes is the one that matters.
  outcomes.forEach((k, v) => stdout.writeln('  ${k.padRight(12)} $v'));
  final deadOpens = records
      .where((r) => r['outcome'] != 'ok' && (r['bytes'] as num? ?? 0) == 0)
      .length;
  stdout.writeln('  served nothing at all: $deadOpens');

  stdout.writeln('');
  stdout.writeln('--- failures by kind ---');
  final fails = <String, int>{};
  for (final r in records) {
    final f = r['fail'];
    if (f is Map) {
      f.forEach((k, v) => fails['$k'] = (fails['$k'] ?? 0) + (v as num).toInt());
    }
  }
  if (fails.isEmpty) {
    stdout.writeln('  none');
  } else {
    final sorted = fails.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      stdout.writeln('  ${e.key.padRight(12)} ${e.value}');
    }
  }

  stdout.writeln('');
  stdout.writeln('--- hosts used ---');
  final hosts = <String, int>{};
  for (final r in records) {
    for (final h in (r['hosts'] as List? ?? const [])) {
      hosts['$h'] = (hosts['$h'] ?? 0) + 1;
    }
  }
  final sortedHosts = hosts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sortedHosts) {
    stdout.writeln('  ${e.value.toString().padLeft(5)}  ${e.key}');
  }

  stdout.writeln('');
  stdout.writeln('--- slowest openings ---');
  final slowest = List.of(served)
    ..sort((a, b) =>
        (b['ttfb_ms'] as num).compareTo(a['ttfb_ms'] as num));
  for (final r in slowest.take(5)) {
    stdout.writeln('  ${r['t']}  ttfb=${r['ttfb_ms']}ms  '
        'bytes=${r['bytes']}  ${r['fail'] ?? ''}  ${r['hosts']}');
  }
}

int _pct(List<int> sorted, int p) {
  if (sorted.isEmpty) return 0;
  final i = ((sorted.length - 1) * p / 100).round();
  return sorted[i];
}
