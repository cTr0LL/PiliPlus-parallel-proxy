// Shared helpers for the dev harnesses. Not part of the app.
import 'dart:io';
import 'dart:typed_data';

/// Harness scripts are run from the repo root, the way tool/jnigen.dart is, so
/// paths here are relative to that rather than to this directory.
const defaultUrlFile = 'tool/parallel_proxy/urls.txt';

class HarnessResult {
  HarnessResult(this.bytes, this.elapsed, this.status, this.resumes)
      : error = null;
  HarnessResult.failed(this.error)
      : bytes = const [],
        elapsed = Duration.zero,
        status = 0,
        resumes = 0;

  final List<int> bytes;
  final Duration elapsed;
  final int status;

  /// How many times the transfer had to reconnect. Non-zero on its own is a
  /// finding: long single-connection reads get cut on some routes.
  final int resumes;
  final String? error;
}

/// Reads [length] bytes from [start] on ONE connection, resuming from where it
/// left off if the connection drops.
///
/// The resume matters for fairness: a real client would not abandon a transfer
/// because the CDN cut it at 40 MiB, and the parallel path already retries per
/// chunk. Reconnect time stays on the clock, because a real client pays it.
Future<HarnessResult> timedGet(
    String url, Map<String, String> headers, int start, int length,
    {int maxResumes = 5}) async {
  final client = HttpClient()..autoUncompress = false;
  final out = BytesBuilder(copy: false);
  final sw = Stopwatch()..start();
  var resumes = 0;
  var status = 0;

  try {
    while (out.length < length) {
      final from = start + out.length;
      try {
        final req = await client.getUrl(Uri.parse(url));
        headers.forEach(req.headers.set);
        req.headers
            .set(HttpHeaders.rangeHeader, 'bytes=$from-${start + length - 1}');
        final resp = await req.close();
        status = resp.statusCode;
        if (status != 200 && status != 206) break;
        await for (final part in resp) {
          out.add(part);
        }
      } on HandshakeException catch (e) {
        return HarnessResult.failed('TLS handshake failed: ${e.message}');
      } catch (e) {
        if (resumes >= maxResumes) {
          return HarnessResult.failed('$e');
        }
      }

      if (out.length >= length) break;
      resumes++;
      if (resumes > maxResumes) {
        return HarnessResult.failed('gave up after $maxResumes resumes '
            '(${out.length} of $length bytes)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    sw.stop();
    return HarnessResult(out.takeBytes(), sw.elapsed, status, resumes);
  } finally {
    client.close(force: true);
  }
}

const bilibiliHeaders = {
  'Referer': 'https://www.bilibili.com',
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
};

/// Total size of the remote file, via a one-byte range request.
Future<int?> fileSize(String url) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final req = await client.getUrl(Uri.parse(url));
    bilibiliHeaders.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final resp = await req.close();
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
    await resp.drain<void>().catchError((_) {});
    if (cr == null) return null;
    final m = RegExp(r'/(\d+)\s*$').firstMatch(cr.trim());
    return m == null ? null : int.parse(m.group(1)!);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The two files bilibili serves for one video. DASH keeps them separate, each
/// with its own mirror list, and the player opens both at once.
class StreamUrls {
  StreamUrls(this.video, this.audio);

  final List<String> video;
  final List<String> audio;

  bool get hasAudio => audio.isNotEmpty;
}

/// Reads both tracks from a urls.txt that uses `[video]` / `[audio]` section
/// markers. A file with no markers is treated as video only, which is what
/// older url files look like.
StreamUrls collectStreams(List<String> args, {bool quiet = false}) {
  final raw = _rawLines(args);
  if (raw.isEmpty) return StreamUrls(const [], const []);

  final video = <String>[];
  final audio = <String>[];
  var target = video;

  for (final line in raw) {
    final cleaned = line.trim().replaceAll(RegExp(r'^"|"$'), '');
    if (cleaned.isEmpty || cleaned.startsWith('#')) continue;
    final marker = cleaned.toLowerCase();
    if (marker == '[video]') {
      target = video;
      continue;
    }
    if (marker == '[audio]') {
      target = audio;
      continue;
    }
    final uri = Uri.tryParse(cleaned);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      stderr.writeln('Skipping line that is not a URL: '
          '${cleaned.length > 60 ? '${cleaned.substring(0, 60)}...' : cleaned}');
      continue;
    }
    target.add(cleaned);
  }

  if (video.isEmpty) {
    stderr
      ..writeln('No video URLs found.')
      ..writeln('Expected a [video] section (or a plain list of URLs).');
    exitCode = 64;
    return StreamUrls(const [], const []);
  }

  if (!quiet) {
    stdout.writeln('video: ${video.length} url(s)');
    for (final u in video) {
      stdout.writeln('  ${Uri.parse(u).host}');
    }
    if (audio.isEmpty) {
      stdout.writeln('audio: none - playback will be SILENT.');
      stdout.writeln('       bilibili serves audio as a separate DASH file; '
          're-copy with the [audio] section.');
    } else {
      stdout.writeln('audio: ${audio.length} url(s)');
      for (final u in audio) {
        stdout.writeln('  ${Uri.parse(u).host}');
      }
    }
    stdout.writeln('');
  }
  return StreamUrls(video, audio);
}

/// Video-track URLs only. For tools that measure one stream.
List<String> collectUrls(List<String> args, {bool quiet = false}) =>
    collectStreams(args, quiet: quiet).video;

/// Reads the raw lines from --file=, then positional args, then ./urls.txt.
List<String> _rawLines(List<String> args) {
  final fileFlag = strFlag(args, '--file');
  final positional = args.where((a) => !a.startsWith('--')).toList();

  if (fileFlag != null) return _readUrlFile(fileFlag);
  if (positional.isNotEmpty) return positional;
  if (File(defaultUrlFile).existsSync()) return _readUrlFile(defaultUrlFile);

  stderr
    ..writeln('No URLs given.')
    ..writeln('')
    ..writeln('Put them in $defaultUrlFile, like:')
    ..writeln('  [video]')
    ..writeln('  https://...baseUrl')
    ..writeln('  https://...backupUrl')
    ..writeln('  [audio]')
    ..writeln('  https://...baseUrl')
    ..writeln('  https://...backupUrl');
  exitCode = 64;
  return const [];
}

List<String> _readUrlFile(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('File not found: $path');
    exitCode = 66;
    return const [];
  }
  return f.readAsLinesSync();
}

int? intFlag(List<String> args, String name) {
  final v = strFlag(args, name);
  return v == null ? null : int.tryParse(v);
}

String? strFlag(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('$name=')) return a.substring(name.length + 1);
  }
  return null;
}
