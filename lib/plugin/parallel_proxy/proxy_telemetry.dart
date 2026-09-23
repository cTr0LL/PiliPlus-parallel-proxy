import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:path_provider/path_provider.dart';

/// Appends one JSON line per served request to a file that survives restarts
/// and can be pulled off the device without root.
///
/// Why not the existing logging:
///   * logcat is a ring buffer - a few hours of use erases the beginning, and
///     it only exists while the phone is attached.
///   * PiliPlus's Catcher2 log is for crashes and stack traces, is gated behind
///     a preference, and lives in app-private storage that adb cannot read.
///
/// This writes to the app's EXTERNAL files directory, which is app-scoped (no
/// storage permission, removed when the app is uninstalled) but readable by:
///
///   `adb pull /sdcard/Android/data/<pkg>/files/parallel_proxy/sessions.jsonl`
///
/// One line per playback rather than per request: weeks of ordinary use stay a
/// few hundred KB, and it is the granularity that answers "slow or broken".
abstract final class ProxyTelemetry {
  /// Rotated at this size, keeping one previous generation. Two videos produce
  /// roughly 300 bytes, so this holds on the order of a thousand playbacks.
  static const _maxBytes = 512 * 1024;

  static File? _file;
  static IOSink? _sink;
  static int _written = 0;
  static bool _initialising = false;

  /// Set up lazily on the first record, so a device without external storage
  /// simply never logs instead of failing at startup.
  static Future<void> _ensureOpen() async {
    if (_sink != null || _initialising) return;
    _initialising = true;
    try {
      final base =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/parallel_proxy');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final file = File('${dir.path}/sessions.jsonl');
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        // Keep exactly one previous generation; older history is not worth the
        // space on a phone.
        final previous = File('${dir.path}/sessions.prev.jsonl');
        if (previous.existsSync()) previous.deleteSync();
        file.renameSync(previous.path);
      }
      _file = file;
      _written = file.existsSync() ? file.lengthSync() : 0;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      if (kDebugMode) debugPrint('ProxyTelemetry -> ${file.path}');
    } catch (e) {
      if (kDebugMode) debugPrint('ProxyTelemetry unavailable: $e');
    } finally {
      _initialising = false;
    }
  }

  /// Never throws: telemetry failing must not disturb playback.
  static void record(Map<String, Object?> entry) {
    () async {
      try {
        await _ensureOpen();
        final sink = _sink;
        if (sink == null) return;
        final line = jsonEncode(entry);
        sink.writeln(line);
        _written += line.length + 1;
        if (_written > _maxBytes) {
          await close();
        }
      } catch (_) {
        // Deliberately silent.
      }
    }();
  }

  /// Flushes and closes. Call on app pause; a later record reopens it.
  static Future<void> close() async {
    final sink = _sink;
    _sink = null;
    _file = null;
    _written = 0;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// Where the file is, for telling the user what to pull.
  static String? get path => _file?.path;
}
