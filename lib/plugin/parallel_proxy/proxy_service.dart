import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/plugin/parallel_proxy/parallel_proxy.dart';
import 'package:PiliPlus/plugin/parallel_proxy/proxy_telemetry.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, debugPrint, visibleForTesting;

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

  /// Deliberately lower than the 16 that `tool/parallel_proxy/bench.dart`
  /// measured as optimal, because raw throughput is not the binding constraint
  /// during playback.
  ///
  /// mpv's demuxer cache here is 4 MiB (`demuxer-max-bytes`), so anything
  /// beyond `concurrency * chunkSize` of read-ahead is fetched and then thrown
  /// away on the next seek. And a seek supersedes the session, which cancels
  /// every in-flight fetch - a cancelled response cannot be kept alive, so each
  /// one destroys a TLS connection and the next session opens that many again.
  /// Seek-heavy content (a 合集, where position is restored between parts) then
  /// churns connections fast enough that the CDN simply stops answering:
  /// chunks time out at 0 bytes received.
  ///
  /// 8 x 512 KiB = 4 MiB in flight, matching what the player will actually
  /// hold, which makes a seek cheap to abandon.
  static int videoConcurrency = 8;
  static int audioConcurrency = 2;
  static int chunkSize = 512 << 10;

  /// Whether to manufacture a pool of CDN hosts by rewriting the signed URL's
  /// hostname, and spread chunks across it - one or two connections per host
  /// rather than the whole window at one.
  ///
  /// This is what Bilibili-thread-ripper does: its resolver rotates a cursor
  /// per concurrent worker over frozen MAINLAND_HOSTS / OVERSEAS_HOSTS lists,
  /// so N threads land on N nodes. It addresses a different problem from
  /// parallelism - bilibili's caching is tiered, and an unpopular video is
  /// simply absent from some edges, so asking a DIFFERENT node can beat asking
  /// the same node harder. It also avoids the per-host rate limiting that
  /// answered our 8-connections-on-one-host bursts with 503s.
  ///
  /// Kept as a switch so it can be A/B'd against single-host on real telemetry,
  /// since the desktop benchmark that argued for single-host only ever measured
  /// a warm object across two overseas mirrors.
  static bool useHostPool = true;

  /// Hosts the signed URL may be rewritten to, mainland first: cold data is
  /// likelier to be resident there, which is the case single-host handles worst.
  /// Unreachable ones cost one connect timeout each and are then blocked by the
  /// proxy's shared per-host health, so listing optimistically is cheap.
  static final List<String> poolHosts = [
    for (final e in const [
      CDNService.ali,
      CDNService.alib,
      CDNService.cos,
      CDNService.cosb,
      CDNService.hw,
      CDNService.hwb,
      CDNService.hw_08c,
      CDNService.aliov,
      CDNService.cosov,
      CDNService.hwov,
      CDNService.akamai,
    ])
      if (e.host != null) e.host!,
  ];

  static ParallelProxy? _proxy;

  /// Recent registrations, oldest first. Quality switches and playurl refreshes
  /// register again, so without this the token map would grow for the life of
  /// the app.
  ///
  /// Four, because PiliPlus registers exactly two per video (the DASH video and
  /// audio tracks), so this holds the current video plus the previous one. That
  /// is the slack needed for a switch, and no more: eviction is what cancels an
  /// abandoned stream's in-flight fetches, and every video kept beyond the
  /// current one is a stream that may still be consuming the per-host
  /// connection budget. At six, the fifth video in a row could not get
  /// connections and failed to open.
  static final List<String> _recent = [];
  static const _keepRegistrations = 4;

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
          chunkSize: chunkSize,
          // Must cover every stream in flight at once, not one: the DASH video
          // and audio tracks share a CDN host, and during a switch the previous
          // video's registrations are still alive. Two videos' worth, plus
          // headroom for the length probes.
          maxConnectionsPerHost: (videoConcurrency + audioConcurrency) * 2 + 8,
          spreadAcrossMirrors: useHostPool,
          onLog: kDebugMode ? (m) => debugPrint('ParallelProxy $m') : null,
          // Persisted in release builds too: this is what makes it possible to
          // answer "was it slow or broken" after days of ordinary use, when
          // logcat has long since wrapped.
          onSession: ProxyTelemetry.record,
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
    await ProxyTelemetry.close();
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
      final backups = mirrorsFor(direct, mirrors);

      final local = proxy.register(
        url: direct,
        backupUrls: backups,
        headers: _headers,
        concurrency: isAudio ? audioConcurrency : videoConcurrency,
        kind: isAudio ? 'audio' : 'video',
      );

      if (kDebugMode) {
        debugPrint(
          'ParallelProxy register ${local.split('/').last.substring(0, 8)} '
          '${isAudio ? 'audio' : 'video'} '
          'host=${Uri.parse(direct).host} '
          'mirrors=${backups.length} '
          'conc=${isAudio ? audioConcurrency : videoConcurrency}',
        );
      }

      _recent.add(local);
      while (_recent.length > _keepRegistrations) {
        final dropped = _recent.removeAt(0);
        if (kDebugMode) {
          debugPrint(
            'ParallelProxy evict ${dropped.split('/').last.substring(0, 8)}',
          );
        }
        proxy.unregister(dropped);
      }
      return local;
    } catch (e) {
      if (kDebugMode) debugPrint('ParallelProxy register failed: $e');
      return direct;
    }
  }

  /// Everything to try besides [direct]: the urls bilibili supplied, plus -
  /// when [useHostPool] is on - the same signed path rewritten onto the other
  /// known CDN hosts.
  ///
  /// Rewriting is only valid for the upos mirror URLs, which carry their
  /// signature in query parameters rather than in the hostname; anything else
  /// is passed through untouched.
  @visibleForTesting
  static List<String> mirrorsFor(String direct, Iterable<String> supplied) {
    final out = <String>{...supplied.where((u) => u != direct)};

    if (useHostPool) {
      final uri = Uri.tryParse(direct);
      if (uri != null && _isSwappable(uri)) {
        for (final host in poolHosts) {
          if (host == uri.host) continue;
          out.add(uri.replace(host: host).toString());
        }
      }
    }
    return out.toList();
  }

  static bool _isSwappable(Uri uri) =>
      uri.path.contains('/upgcxcode/') &&
      (uri.host.endsWith('.bilivideo.com') ||
          uri.host.endsWith('.akamaized.net'));
}
