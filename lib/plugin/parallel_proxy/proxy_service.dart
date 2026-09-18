import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// Owns the loopback proxy that fetches CDN media in parallel byte ranges.
///
/// Bilibili's CDN throttles per connection rather than per client, so pulling
/// one file over many connections is far faster on a cold object. Measured on
/// one real route: 0.35 MiB/s direct vs 1.95 MiB/s through the proxy, on a
/// stream the direct path could not carry at all.
///
/// [accelerate] wraps a URL the caller has already chosen - normally via
/// `VideoUtils.getCdnUrl` - and hands back a `http://127.0.0.1:...` URL backed
/// by it.
///
/// The chosen URL is passed in rather than selected here so this file does not
/// depend on `VideoUtils`, which reaches `Pref` and from there most of the app.
/// That keeps the service testable on a stock Flutter SDK, and leaves the CDN
/// choice visible at the call site.
abstract final class ProxyService {
  /// Off switches the whole thing back to plain [VideoUtils.getCdnUrl].
  // TODO: surface in settings and persist via Pref.
  static bool enabled = true;

  /// Measure with `parallel_proxy/bin/bench.dart` rather than guessing; the
  /// useful value is a property of the route. Audio gets far less because it
  /// carries ~2% of the video bitrate and would otherwise be mostly handshakes.
  static int videoConcurrency = 16;
  static int audioConcurrency = 4;

  static ParallelProxy? _proxy;

  /// Recent registrations, oldest first. Quality switches and playurl refreshes
  /// register again, so without this the token map would grow for the life of
  /// the app. Kept deliberately slack: a switch can leave the player briefly
  /// reading the previous URL, and unregistering it out from under mpv would
  /// stall playback.
  static final List<String> _recent = [];
  static const _keepRegistrations = 6;

  static Map<String, String> get _headers => const {
    'Referer': HttpString.baseUrl,
    'User-Agent': BrowserUa.pc,
  };

  static bool get isRunning => _proxy?.isRunning ?? false;

  /// Binds the loopback server. Safe to call more than once. Never throws -
  /// a proxy that will not start must not stop the app from playing video.
  static Future<void> start() async {
    if (_proxy != null) return;
    try {
      final proxy = ParallelProxy(
        config: ParallelProxyConfig(
          concurrency: videoConcurrency,
          // Video and audio usually share a CDN host, so this must cover both.
          maxConnectionsPerHost: videoConcurrency + audioConcurrency + 8,
        ),
      );
      await proxy.start();
      _proxy = proxy;
      if (kDebugMode) {
        debugPrint('ParallelProxy listening on 127.0.0.1:${proxy.port}');
      }
    } catch (e) {
      _proxy = null;
      if (kDebugMode) debugPrint('ParallelProxy failed to start: $e');
    }
  }

  static Future<void> stop() async {
    final proxy = _proxy;
    _proxy = null;
    _recent.clear();
    await proxy?.stop();
  }

  /// Routes [direct] through the proxy, using the rest of [mirrors] as
  /// failover. Falls back to [direct] whenever anything is not right, so the
  /// worst case is ordinary single-connection playback.
  static String accelerate(
    String direct,
    Iterable<String> mirrors, {
    bool isAudio = false,
  }) {
    final proxy = _proxy;
    if (!enabled || proxy == null || !proxy.isRunning) return direct;
    if (!direct.startsWith('http')) return direct;

    try {
      // getCdnUrl may rewrite the host to the user's preferred CDN, so the
      // chosen URL is not necessarily one of the originals. Everything else
      // becomes failover.
      final backups = mirrors.where((u) => u != direct).toList();

      final local = proxy.register(
        url: direct,
        backupUrls: backups,
        headers: _headers,
        concurrency: isAudio ? audioConcurrency : videoConcurrency,
      );

      _recent.add(local);
      while (_recent.length > _keepRegistrations) {
        proxy.unregister(_recent.removeAt(0));
      }
      return local;
    } catch (e) {
      if (kDebugMode) debugPrint('ParallelProxy register failed: $e');
      return direct;
    }
  }
}
