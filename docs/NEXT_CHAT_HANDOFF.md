# dev.87 handoff

唯一后续基线：`zic_v0.31.0-dev.87_cloudflare-metadata-local-artifact.zip`。不得混入 dev.86 或更早候选。

本轮关键边界：Cloudflare 通过 `ErrorCode.sourceVerificationRequired` 传播；`network_bridge` 执行通用 WebView/Cookie 能力，`plugin_host` 只解析插件协议和 opaque 作品 URL；详情下拉刷新、右上角作品 WebView；来源分类/标签与书架分类分离；adaptive profile model v5；持久 promoted artifact 只在原子 metadata/长度有效时跳过 CRC 重扫，默认 restore 仍完整校验。

下一环境优先运行 Flutter analyze/test 和 Android build，再用用户 trace 同类 5–20 MB 本地 WebP 验证 artifactSource readMicros。不得通过关闭 7/3 预取、缩小 2/1 预解码、降低 5/3/2 lane 或绕过 DownloadSession 掩盖慢读。

# dev.86 handoff

唯一后续基线：`zic_v0.31.0-dev.86_network-bridge-compile-closure.zip`。

完成：补齐 `ComicDetailsSourceWebViewOpener` 编译闭包；新增 `network_bridge` 并迁移通用来源 WebView、Cookie/localStorage 快照、Cloudflare interceptor、Android CookieJar 与 fallback DNS；删除 plugin host 旧登录通道/Activity/store 与 controller 网络转发；App composition 直接注入 network facade；浏览器进程由 App placeholder 组合，snapshot 通过原子文件跨进程交接；Mihon ABI adapter 改为 parent-first 消费共享网络类，并增加运行时完整性与 shrinker 门禁。dev.85 的章节目录失败语义、256 KiB chunk、本地文件/SAF 流式和 Pipeline 策略未改。

设备侧必须验证：`flutter analyze`；`network_bridge`、`plugin_host_bridge`、App 受影响测试；Android kernel/debug/release；18comic/JMComic Cloudflare 自动和手动 WebView 恢复；Venera Web 登录 snapshot；多进程 WebView/Cookie 持久化。rhttp 尚未引入，后续不得直接放入 plugin host；应先作为共享 transport backend 评估。

不得恢复：未定义 callback 类型、`openMihonLogin`/`readExternalLoginSnapshot` 插件桥私有通道、plugin host 私有 Cloudflare/CookieJar/DNS、仅凭目录空创建 synthetic、整文件 SAF Reader 路径，或通过缩窗/降并发掩盖错误。

## Historical dev.85 record

### dev.85 handoff

唯一后续基线：`zic_v0.31.0-dev.85_cloudflare-catalog-local-stream.zip`。

完成：staged 覆盖、Mihon Cloudflare runtime interceptor、章节失败/权威空目录与 synthetic gallery 的区分、详情错误 + WebView 恢复入口、旧 synthetic 目录协调淘汰、256 KiB 数据块、普通文件直接分块、Android `content://` bridge v4 流式/range 生命周期，以及 owner 测试/门禁/文档。

设备侧必须验证：18comic/JMComic 在未通过 Cloudflare 时显示错误而不是单章节；WebView 完成验证后重试可恢复真实章节；真正无 chapter-list API 的 gallery 仍能通过非空正文预检生成一章；大尺寸本地文件和 SAF `content://` 首帧/翻页耗时及内存峰值改善；range resume 与取消关闭无句柄泄漏。运行 `flutter analyze`、受影响 package tests、App tests、Android kernel/debug/release 和真机契约。

不得恢复：仅凭空列表创建单章节、在 Presentation 解析 Mihon token、完整 `readDocument` 作为 Reader 常规路径、把 content URI 预复制到 App 目录后才读取、或修改 7/3、2/1、current/transition、5/3/2 掩盖 I/O/请求错误。

## Historical dev.84 record

`dev.84` 仅为历史记录；后续不得回退或混入该树之外的候选补丁。Mihon 与 VibeVenera 参考源码继续只读。

## Historical dev.83 record

The dev.83 baseline below is historical only. Future work must use the dev.84 ZIP named above. Mihon and VibeVenera references remain read-only.

### Completed in dev.83

- Fixed missing session-owner imports for `DecodeSnapshot`, `DecodeState` and `UploadState`.
- Replaced URI-scheme profile selection with one stable Reader profile for every source: +7/-3 download, +2/-1 decode warm, current/transition upload, 5/3/2 lanes.
- Migrated the portable VibeVenera adaptive model v4: title/tag/category/language/explicit type, tag-weighted geometry and softmax, cover exclusion, two geometry or actual decoded-animation samples, 0.60 apply/0.80 stop, metadata fingerprint and per-comic persistence.
- Ordinary source reading direction is fallback only; manifest animatedHint and a static WebP suffix are not actual animation evidence.
- Snapped continuous extents to DPR, removed redundant stitched FittedBox/ordinary per-page clip/repaint boundaries, and direct-filled the authoritative texture box without overlap.
- Added deterministic owner tests and ADR 0067.

### Device/toolchain validation still required

1. Run `flutter analyze`, affected pipeline_runtime/reader_runtime/reader/texture_bridge/App tests, then full Dart/Flutter tests.
2. Build Android kernel snapshot and debug/release.
3. Open a long Mihon/Venera chapter near its middle and verify policy telemetry reports 11 downloads and 4 decodes before a transition.
4. Reopen animated-title and static-WebP comics; animated metadata must select paged mode, static WebP must wait for actual evidence, and results must persist per comic.
5. Scroll stitched vertical pages slowly and with fling at multiple DPRs; no 1–2 px line may appear at any scroll position.

### Rejected regressions

Do not restore source-specific Reader windows, call a second preloader from App/Reader, classify every WebP as animated, treat ordinary source direction as adaptive fact, or hide seams with overlap/negative translation/cropping/masks.

## Historical dev.82 handoff

# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.82_animation-source-grid-trace-stability.zip`

Do not merge dev.65–81 candidates, overlays or remembered source trees. Mihon and VibeVenera references remain read-only. The user-provided libwebp 1.6.0 archive is validation input only.

## Completed in dev.82

- Animated WebP ANMF rectangles are blended/disposed on the source canvas and the complete frame is scaled once; Presentation and texture layers do not own fragment geometry.
- Source growth and frame consumption are independent wake reasons. A consumed timed frame refills decode even after the download is sealed.
- Source wake and committed-byte telemetry are aggregated at 64 KiB boundaries plus seal/failure; downstream work is submitted only after real snapshot changes.
- Raw Trace export defaults to 10000 events while UI projection remains 500; authoritative errors and terminal lifecycle events remain uncoalesced.
- Controlled transport tests no longer await controller close while the iterator is paused; geometry uses tolerance rather than exact binary-double equality.

## Device/toolchain validation still required

1. Run `flutter analyze`, affected downloads/sessions/reader tests, then the complete Dart/Flutter suite.
2. Run Rust tests and build Android debug/release or at least kernel snapshot.
3. Reopen the exact WebP shown in the dev.81 screenshot: no horizontal strip displacement may appear in continuous mode.
4. Let the same animation finish downloading and remain visible through at least one full loop; playback must continue without source growth.
5. Export a short diagnostic capture and verify committed-byte/decode/upload no-op storms are absent and the file stays bounded.

## Rejected regressions

Do not scale animation fragments independently, couple playback progress to network revision, wake every decoder for every tiny chunk, hide the problem by shrinking windows/lanes, or restore socket/fixed-time/lazy-child/exact-double tests.

## Historical dev.81 handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.81_route-first-mihon-streaming-stability.zip`

Do not merge dev.65–80 candidates, overlays or remembered source trees. Mihon and VibeVenera references remain read-only. The user-provided libwebp 1.6.0 archive is validation input only.

## Completed in dev.81

- Mihon normal image bodies no longer cross the plugin RPC as complete bytes. Runtime resolves final URL/headers; host transport streams into the existing DownloadSession. Complete-byte fallback is allowed only after direct request and refreshed-plan request fail.
- DownloadSession owns `networkStartLength`; unknown-length current-page progress becomes receiving after the first new chunk.
- UploadSession drains active upload Futures before platform slot release and ignores stale revision failures, addressing the trace-confirmed `Failure(texture): frame upload failed` during rapid page transitions.
- Chapter selection immediately pushes a deferred black Reader route; chapter/source/artifact/loader preparation happens inside it.
- WebP and ordinary images use centered unified Presentation. Continuous geometry tests moved to a pure owner object.
- Real sockets in downloads/App gateway tests, fixed 30-second waits, `pumpAndSettle`, lazy-child counts, magic scroll thresholds and the gate-mandated 400 ms double-tap drain were removed. Replacements use controlled Stream/Future, the injected monotonic clock or pure geometry.
- Android Trace export compiles on FlutterActivity using the platform document Intent result lifecycle.

## Device/toolchain validation still required

1. Run `flutter analyze`, affected downloads/sessions/reader/plugin_host/App tests, then the complete Dart/Flutter suite.
2. Build Android debug/release or at least kernel snapshot.
3. On device, open an uncached Mihon WebP chapter: sourceReady/bytesCommitted must advance in chunks before seal, progress must change from connecting to receiving, and first frame must appear before full completion when the file supports it.
4. Rapidly move 30→31→30 while animated frames upload; no stale texture failure or playback stall may appear.
5. Tap a cold remote chapter; the Reader route must appear immediately while chapter preparation continues inside it.
6. Verify wide/tall WebP and ordinary images remain centered and aspect-preserving.

## Rejected regressions

Do not restore plugin full-body RPC as the normal path, wait for chapter preparation before navigation, release a platform slot while its upload Future is active, invent progress percentages, shrink windows/lanes, or restore real-socket/fixed-time/lazy-child tests.


## Historical dev.80 handoff


## Sole baseline

Use only:

`zic_v0.31.0-dev.80_streaming-raster-trace-export.zip`

Do not merge dev.65–79 candidates, overlays or remembered source trees. Mihon
and VibeVenera references remain read-only. The user-provided libwebp 1.6.0
archive is validation input only.

## Completed in dev.80

- Added monotonic ingress source revisions and per-DecodeId consumed-revision
  tracking. Same-key follow work drains source growth/seal changes that arrive
  during an active decode and exits without repeating an already-consumed latest
  revision.
- Unknown Content-Length transfer is projected as connecting until committed
  bytes advance, then receiving with real received-byte count. No fake percent.
- Added one `AlignedRasterSize` contract for static images, DecodeTarget and
  native WebP: contain, source aspect, integer comparison and paired 8-pixel
  physical alignment. Dart and Rust share fixture vectors.
- `MediaAspectViewport` is the only fit decision. Unknown intrinsic dimensions
  keep requested contain/fitWidth instead of filling the viewport; authoritative
  header/static dimensions are not replaced by aligned output-buffer dimensions.
  WebP prefix reads drain lengths received while a read is active.
- Android raw JSONL export uses an App-owned SAF `CreateDocument` channel.
  Debug Presentation only calls injected capabilities. Clipboard copy is a
  separate 64 KiB UTF-8 raw projection and reports truncation/failure.
- Added ADR 0064, dev.80 audit/static gate and owner tests. +7/-3, +2/-1,
  current/transition and 5/3/2 remain unchanged.

## Device/toolchain validation still required

1. Run `flutter analyze`, all Dart/Flutter package and App tests, Rust tests, then
   Android debug/release or at least kernel snapshot.
2. Use a large animated WebP whose first complete frame arrives before download
   completion. It must leave page loading while transfer remains active and keep
   advancing as later source revisions arrive.
3. Compare wide, tall and near-square JPEG/PNG/GIF/WebP pages in paged and
   continuous fitWidth modes across multiple DPRs. No format may stretch to the
   viewport; output raster dimensions should be 8-pixel aligned.
4. Copy a large raw trace and confirm the UI reports the bounded copied count.
   Export the full raw filtered trace through Android's document picker and
   verify the resulting JSONL opens after app background/foreground.
5. Re-run long-lived Venera, custom-locator cover cache, continuous-scroll and
   adaptive-animation checks from dev.79.

## Rejected regressions

Do not wait for full download before decode, restore Presentation-owned source or
cursor, add format-specific fit rules, independently resize X/Y, use `BoxFit.fill`
as a viewport fallback, invent unknown-length percentages, call Android
`file_selector.getSavePath()`, export the coalesced UI ring, or reduce preload and
lane settings.
