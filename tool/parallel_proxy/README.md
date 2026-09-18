# parallel_proxy

A loopback HTTP server that mirrors a single remote file, fetching it from the
CDN in several concurrent byte ranges and re-serialising the result into one
ordinary Range-capable stream.

The point: bilibili's CDN throttles per connection, not per client, and the
playurl response hands you several mirror hosts for free. Fetching one file over
6 connections across those mirrors is usually much faster than over one —
especially on an international route. This is the same idea as
[Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper),
moved from a browser extension into something a native player can use.

It sits in front of the player rather than inside it, so it works with libmpv
(what PiliPlus uses via media_kit), which exposes no pluggable data source of
its own.

## Layout

The proxy itself ships with the app; everything here is the harness used to
develop and measure it. There is deliberately only ONE copy of the server.

```
lib/plugin/parallel_proxy/parallel_proxy.dart   the server (the app's copy)
lib/plugin/parallel_proxy/proxy_service.dart    app wiring: start, accelerate
test/plugin/parallel_proxy_test.dart            integration test (flutter test)

tool/parallel_proxy/selftest.dart      21 checks against a local origin
tool/parallel_proxy/resume_probe.dart  10 checks of reconnect-on-drop
tool/parallel_proxy/dev_server.dart    serve / byte-verify against the real CDN
tool/parallel_proxy/bench.dart         find the connection-count ceiling
tool/parallel_proxy/play.ps1           start the proxy and play it in mpv
```

Run everything from the repo root, the way `tool/jnigen.dart` is run.

## Testing

Run everything from this folder (the one holding `pubspec.yaml`).

### Offline, no bilibili URL needed

```bash
dart run tool/parallel_proxy/selftest.dart
```

```bash
dart run tool/parallel_proxy/resume_probe.dart
```

```bash
flutter test test/plugin/parallel_proxy_test.dart
```

`selftest.dart` stands up a local origin server with a known 20 MiB body and
checks the proxy's output is byte-identical across full reads, multi-chunk
ranges, sub-`minParallelSize` reads, suffix ranges, HEAD, unsatisfiable ranges,
a mirror that ignores `Range`, and a client that hangs up mid-stream. 17 checks,
all passing as of the last run.

### Against the real CDN

Bilibili uses DASH, so **video and audio are two separate files** with separate
mirror lists. Grab both or playback is silent. From a browser console on a video
page:

```js
const d = window.__playinfo__.data.dash, v = d.video[0], a = d.audio[0];
copy('[video]\n' + [v.baseUrl, ...(v.backupUrl ?? [])].join('\n') +
     '\n[audio]\n' + [a.baseUrl, ...(a.backupUrl ?? [])].join('\n'));
```

That produces a `tool/parallel_proxy/urls.txt` shaped like:

```
[video]
https://...baseUrl
https://...backupUrl
[audio]
https://...baseUrl
https://...backupUrl
```

A file with no section markers is read as video only, so older url files still
work — they just play silent.

then write the clipboard straight to the file (works from cmd or PowerShell):

```
powershell -Command "Get-Clipboard | Set-Content -Encoding utf8 tool/parallel_proxy/urls.txt"
```

```bash
dart run tool/parallel_proxy/dev_server.dart --verify --cold
```

**Cold vs warm is the whole ballgame.** A file you have already fetched is
cached at the CDN edge and will stream fast on a single connection - there is no
per-connection throttle left to defeat, and the proxy's extra TLS handshakes
make it *slower*. Parallel fetching wins on cold objects, which is also when
playback actually stalls. Measured on one route, the same file went 0.36 -> 2.25
-> 6.59 -> 25.89 MiB/s on a single connection across four successive runs,
purely from warming.

So: use a video you have never opened, and run `--cold` **first**. Benchmarking
warms the cache, and there is only one cold measurement per file.

`--cold` runs correctness on a small shared window, then measures speed on two
*disjoint* regions - otherwise the direct leg would pull exactly the bytes the
proxy leg then reads, and the proxy would be scored against a cache the test
itself just filled.

Plain `--verify` (both legs on the same bytes) is still right for a warm file.

### Against a real player

libmpv is what PiliPlus plays through, so mpv is the closest desktop stand-in
for the app. `tool/play.ps1` starts the proxy, hands mpv the local URL, and
stops the proxy afterwards:

```
powershell -ExecutionPolicy Bypass -File .\tool\play.ps1
```

Add `-Decode` for a headless full decode (silence means clean), `-Seek` for the
repeated-seek stress test that exercises cancel-on-disconnect, or `-Check` to
just print the URL.

Two Windows notes baked into the script: the shinchiro winget build of mpv does
**not** add itself to PATH (it lands in `C:\Program Files\MPV Player\`), and
Windows blocks `.ps1` execution by default, hence `-ExecutionPolicy Bypass`.
Running `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once removes the
need for that prefix.

By hand, if you prefer two terminals:

```bash
dart run tool/parallel_proxy/dev_server.dart
```

```
& "C:\Program Files\MPV Player\mpv.exe" "<local url>"
```

**Do not use `--frames=N` or `--length=N` to shorten these.** Cutting mpv off
mid-packet leaves a partial NAL in the demuxer and prints `Invalid NAL unit
size` / `Packet corrupt`, which reads exactly like stream corruption and is not.
Let the decode finish, or quit cleanly from a script. Likewise `Immediate exit
requested` and `root atom ...: partial file` at shutdown are mpv tearing down,
not proxy faults.

**mpv quits instantly if stdin is closed.** It watches the terminal for
keypresses, so under a CI runner, a tool harness, or a piped shell it sees EOF
and exits with no output and no error — indistinguishable from a playback
failure. `play.ps1` launches the headless modes via `Start-Process` with
`--no-input-terminal` for exactly this reason. Interactive use is unaffected.

Verified this way on a 4K60 / 16.3 Mbps source: probe and open, video and audio
decoding together (`A-V: 0.000`), a full 5-minute decode with **zero errors** in
328s, and 7 forward/backward seeks with nothing reported between them.

Note what that throughput means. 328s for 304s of content is ~0.93x realtime, so
that particular 4K60 stream would still stall slightly — the proxy gets it close
but not clear. At 1080p (~3 Mbps) the same route has large headroom. Without the
proxy, the cold single-connection rate on this link was 0.35 MiB/s, which does
not carry 1080p either.

### Finding the ceiling

If `--verify` shows correct bytes but no speedup, `bench.dart` measures whether
parallelism helps on this route at all, with no proxy involved:

```bash
dart run tool/parallel_proxy/bench.dart
```

It reports per-mirror throughput (an uneven mirror set makes plain round-robin
worse than using the best one alone) and aggregate throughput at 1/2/4/8/16
connections. A flat curve means the link saturates at one connection and no
multi-threaded fetcher can help.

Do **not** paste signed URLs as command-line arguments. They contain `&`, which
cmd.exe treats as a command separator even inside quotes if the quoting is at
all off, and they can exceed the 8191-character line limit. `tool/parallel_proxy/urls.txt`
is gitignored - those URLs are signed and carry your account id.

`--verify` pulls the first 16 MiB through the proxy and again directly, reports
both rates, and byte-compares them. The comparison is the part that matters: a
mirror that silently returns the wrong window shows up here and nowhere else.

Without `--verify` it stays up and prints a local URL you can hand to `ffplay`,
`mpv`, VLC or `curl`.

## How it is wired in

Already done; this is the map, not a to-do list.

**`main.dart`** calls `await ProxyService.start()` right after
`MediaKit.ensureInitialized()`. It swallows its own errors, so a proxy that will
not bind never stops the app from playing video.

**`lib/pages/video/controller.dart`** routes the four DASH playback sites
through it. The chosen CDN url is passed in rather than looked up inside the
service, which keeps `ProxyService` free of `VideoUtils` - that import reaches
`Pref` and from there the whole widget layer, which would make the service
untestable without a patched Flutter SDK:

```dart
videoUrl = ProxyService.accelerate(
  VideoUtils.getCdnUrl(firstVideo.playUrls),
  firstVideo.playUrls,
);
audioUrl = ProxyService.accelerate(
  VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true),
  firstAudio.playUrls,
  isAudio: true,
);
```

**The player needs no changes.** PiliPlus already joins the two DASH tracks with
mpv's EDL protocol, and the `%N%` length prefix it writes is the *url string's*
length, taken from the variable - so shorter loopback urls just work:

```dart
video = ('edl://!no_chapters;'
    '%${video.length}%$video;'
    '!new_stream;!no_chapters;'
    '%${audio.length}%$audio');
```

**`AndroidManifest.xml`** points at `@xml/network_security_config`, which
permits cleartext to `127.0.0.1` only. Without it the player cannot reach the
proxy at all: PiliPlus targets SDK 37, so cleartext is off by default - and that
is driven by targetSdk, not by the OS version, so it applies on Android 8 too.

**No foreground service needed.** PiliPlus already runs one for background audio
(`com.ryanheise.audioservice.AudioService`) and the proxy lives in that process.

Still on `getCdnUrl` and therefore unaccelerated: the `durl` (FLV/MP4) playback
paths and every download path. They would work the same way; they are simply
untested.

## Design notes

**Read-ahead needs no heuristic.** At most `concurrency` chunks are scheduled
past the write cursor, and `flush()` stops completing once the player stops
draining the socket, which stops the loop scheduling more. TCP backpressure is
the governor. Memory and read-ahead are both bounded by
`concurrency * chunkSize` (16 MiB by default).

**Video and audio are separate registrations.** DASH splits them into two files,
and the player opens both at once. `register()` takes a per-file `concurrency`
because the audio track carries ~2% of the video bitrate — giving it the video's
16 connections would be almost pure handshake cost, which matters for battery on
a phone. The default here is 4. `maxConnectionsPerHost` must cover the *sum* of
both, since they usually share a CDN host; it defaults to `concurrency * 3`.

**Mirrors are failover, not load balancing.** `spreadAcrossMirrors` defaults to
false: the proxy holds the primary and only moves to a backup once the primary
is penalised. Measured on one real route, spreading 8 connections across two
mirrors gave 10.38 MiB/s versus 10.51 MiB/s on the best mirror alone — no gain,
while dragging traffic onto a host 1.4x slower. The throttling worth attacking
is per-connection, so the win comes from connection count, not host count. Check
with `bench.dart` before flipping this on.

**Cancel-on-disconnect** is the part that needs care. A seek is the player
dropping the socket. `res.done` erroring sets `session.cancelled`; that flag is
checked inside the `await for` reading each upstream chunk; throwing out of an
`await for` cancels the subscription and closes the upstream socket. That chain
is what stops you paying for bytes nobody will watch.

**Chunk validation** rejects non-206 responses, mismatched `Content-Range`, and
short or overlong bodies, then rotates to another mirror and puts the bad one in
a 30s penalty box. This matters more than it looks: a node that ignores `Range`
and streams from byte 0 would both corrupt the output and saturate the link.

**dart:io footguns handled:** `maxConnectionsPerHost` defaults to 6 and would
otherwise silently cap concurrency; `autoUncompress` must be off or byte
accounting breaks; reads under 256 KiB skip parallelism so FFmpeg's header probe
doesn't open 6 connections; suffix ranges (`bytes=-N`, used when hunting for a
trailing `moov`) are parsed.

## Known gaps

- **The primary mirror is whichever one bilibili listed first**, which is not
  necessarily the fastest — on one measured file the two differed by 3.6x, and
  the ordering changed between videos. With `spreadAcrossMirrors: false` the
  proxy holds `mirrors.first` regardless of quality. It should race the mirrors
  once at registration and keep the winner. Until then, reorder `urls.txt` by
  hand when testing.
- **No adaptive back-off.** On a warm, already-fast object the parallel path is
  slower than a single connection, because 16 TLS handshakes cost more than the
  throughput they buy. The proxy should notice high single-connection throughput
  and stop splitting. It does not yet.
- Verified for correctness against the local test origin and a real CDN. Nothing here has yet touched a
  real bilibili CDN node, so 403 behaviour, real mirror quality and the actual
  speedup are all still unmeasured.
- **Signed URLs expire** after roughly two hours. Nothing here refreshes them, so
  a long session will start 403ing mid-playback. Needs a re-register callback.
- Runs in-process, not in an isolate. Per-chunk work is just a socket write, so
  this is the right starting point — move it only if jank actually shows up.
- No disk cache: seeking backwards refetches.
- Mirror selection is round-robin plus a penalty box, not bandwidth-ranked.
