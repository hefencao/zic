## dev.97 状态

设备 Trace 共 6486 条、4,147,260 bytes，确认多次 50% 翻页在 `pageCurrent` 前后出现 outgoing `pageOutputReleased(reason=demand-detached)`，随后同页又以 transition demand 加回。根因是 `onPageChanged` 的整数 observation，而不是图片下载失败。源码现保留真实 PageController fractional position，默认 50% 完成播放所有权交接，并在 late UploadSession snapshot 后重投影 viewport。Debug export 对高频事件做固定窗口摘要，长本地 identity 改为稳定 hash+长度；错误与生命周期边缘不合并。用户报告的三处 Dart capability 编译错误和 libwebp CRLF patch 拒绝也已关闭。当前环境仍无 Flutter/Dart、Cargo/Rust、Gradle/Android SDK，故 analyzer、Dart/Flutter tests、native/Android 构建和真机结果必须列为未验证。

## dev.96 状态

验证明细见 `docs/audits/dev96-validation-results.md`。

已完成本地 Animated WebP 播放链的所有权修复：两个 Dart decode isolate 由 bridge 进程级常驻，并由 App composition 在 `runApp` 前显式等待预热完成，current 保留一个槽；sessions 对 same-key transition→current 使用 follow，避免取消不可中断 native work；current 保留两个 successor。libwebp 锁定 1.6.0 并加入自动补丁准备链，VP8 大 workspace 按 OS decode 线程复用，帧内线程关闭，未引入 8 线程 worker interface。native 输出改为预乘 RGBA，Android 只复制且不每帧配置 Surface，Flutter fallback 删除二次预乘。流式 metadata 增长会主动刷新 demux，小于 8 px 的 target 不再放大，本地 ingress 统一 1 MiB。

当前环境缺少 Flutter/Dart、Rust、Android SDK/NDK，不能执行 analyzer、Flutter package tests、cargo 或 Android build；repository Python/static gates、shell 语法、补丁 fixture 与干净解压复验作为本环境可执行证据。上游 libwebp fetch 在当前环境受 DNS 限制，因此真实 1.6.0 tree 上的 patch/build 仍列为外部未验证项。

## dev.95 状态

已在 dev.94 唯一基线上继续对照 VibeVenera 的通用媒体 Pipeline/libwebp。高性能设备 Trace 中 native decode 中位约 70.7 ms、Android blit 中位低于 1 ms，但首帧仍约 1.7–2.3 秒；确认主要额外工作来自 promoted artifact 整页物化/重复读取、临时 session 文件逐块等待、Dart→native 双复制以及 source-size canvas 的完整二次缩放。当前持久缓存通过 `ArtifactCacheStreamStore` 直接流入唯一 DownloadSession，流式 store 不再由 read pool 并行整页 prime；Artifact 改用 IOSink 缓冲。native ABI 6 增加 expected capacity、reserve/commit，使 Dart 直接写 native source committed prefix。WebP descriptor 受控刷新，fragment 由 libwebp 直接缩放到共享端点映射的 target rectangle，并在 target canvas blend/dispose。repository/Dart structure、dev.75–dev.95、Android/Mihon/Venera/Reader/Pipeline/UI、native header 和本地 libwebp host smoke 正在/已按当前环境验证；Flutter/Dart/Rust/Gradle/Android 工具链和真机 200 ms 目标仍需外部环境复验。

## dev.94 状态

已在 dev.93 唯一基线上迁移 VibeVenera 中与 Venera 协议无关的 WebP 执行结构。用户 Trace 共 798 条事件：`frameDecoded` 17 次，total decode 中位约 124893 µs；Android texture native blit 中位约 5625 µs，而 platform round trip 中位约 770103 µs、最大约 1689081 µs，bridge 等待占主导。根因是 ZIC 在 UI isolate 同步执行 native decode，且 native decoder 逐帧重新 demux 完整 source。现在 bridge 使用两个常驻 decode Isolate，只传 native cursor/frame 地址；media_core 持久缓存 source-relative frame descriptors，source length/seal 变化才重建，libwebp advanced config 开启线程，并删除每帧完整 demux、第二份压缩快照和 full-canvas clone。source-grid blend/dispose 和既有 texture serial blit 保持不变。当前 repository/Dart structure、dev.82/dev.94 gate 与本地 libwebp 1.6.0 C smoke 已通过；环境仍无 Flutter/Dart/Gradle/Android SDK/Cargo/rustc，真实 analyzer、package tests、Rust/Android 编译、APK 和设备帧率需用户环境复验。

## dev.93 状态

用户确认 dev.92 不再持续无限 loading，但设备 Trace 显示本地动画仍明显卡顿。2753 条事件中，动画帧 duration 主要为 33/34 ms，而 `frameDecoded.decodeMicros` 中位数约 124 ms；旧实现把当前动画 output 计为 prepared depth 1，导致当前帧显示期间不预解码 successor，deadline 后才开始下一帧工作。本轮将动画 output 的 prepared depth 改为 0，在同一 DecodeSession/FrameHolder 中预解码一个 successor，并保持 deadline 前不提前替换、deadline 后原子替换。Android texture telemetry 新增 round-trip 与 bridge 分解。本地文档桥协议升至 v5：seekable descriptor 不再逐 chunk 往返 MethodChannel，而由 Dart 通过同进程 `/proc/self/fd` 直接 256 KiB 读取；不可 seek provider 保留旧 fallback。错误报告中的静态 cursor fixture、50/50 viewport、source seal revision 和本地媒体 viewport 测试已按归属修正。当前静态/契约验证通过；Flutter/Dart/Android 真机结果仍待用户环境复验。

## dev.92 状态

用户在 dev.91 上实际操作回切后提供的 1337 条 Trace 证明此前修复不完整：6 次 page mount 仅 3 次 first frame；3 次已呈现帧的 duration 全为 0，却各自产生 playback due，之后对应 identity 在 depth=0 上反复 decoding/ended，且没有 pageOutputReleased，说明 output 是被播放推进内部提前移除。现已使零时长 timer 保持 idle；动画 advance 保留旧 output、以 preparedDepth=0 请求 successor，新帧成功上传后原子替换；有限 EOF 保留最后帧并输出 playbackCompleted。错误报告中的 storage 测试 API 与 texture viewport fixture 已按归属修复。当前 repository/Dart structure、dev.75–dev.92、Android/Mihon/Venera/Reader/Pipeline/UI、共享浏览器 Kotlin、native header 与本地 libwebp 1.6.0 fixtures 已通过；环境无 Flutter/Dart/Gradle/Android SDK/Cargo，analyzer、Dart/Flutter tests、APK/kernel、Rust 与设备结果仍未验证。

## dev.91 状态

已在 dev.90 唯一基线上修复页面 output 生命周期错误。用户 Trace 的 14 次 page mount 只有 7 次首帧；首次成功页面返回后，多个 decode identity 在 depth=0 下持续 `decoding -> ended`，Upload 停在 `waitingFrame`。根因为 upload 已消费 FrameHolder，output 离开 current/transition 后被退休，但 decode demand 仍在预解码窗口，cursor 未 detach/restart。现在 demand detach 与 frame-budget trim 都由 UploadSession 通知 DecodeSession；空 holder 重建 cursor，retained demand 由 Coordinator follow-up。新增 source/cache read 聚合、decode/upload/present timing、playback lateness 与 output retirement Trace。当前 repository/Dart structure、dev.75–dev.91、Android dependency/Trace、Mihon ABI/classloader/chapter、Venera、Reader/Pipeline/UI、共享浏览器 Kotlin、native header 与本地 libwebp 1.6.0 fixtures 均通过；Flutter/Dart/Gradle/Android SDK/Cargo 不可用，analyzer、Dart/Flutter tests、APK/kernel、Rust 和真机结果仍未验证。

## dev.90 状态

已在 dev.89 唯一基线上修复 Mihon ABI asset 的 network runtime 编译闭包：snapshot store 已进入 runtime source set、完整性检查与 keep。设备 Trace 中 439/440 长度的同源 identity 分别持有 342/1 章，且 syntheticCount 均为 0；确认根因是 Mihon `comicId` 编码可变 SManga 模型，而非卡片 key 或 synthetic fallback。source adapter 现提供规范化 URL 的 comparison-only canonical identity，catalog 合并别名并保留章节最完整的原始 locator。远程详情接受 canonical-equivalent 快照，App 对 canonical group 阻止单章节回归，并输出脱敏 alias Trace。旧精确 ID 路由 facade 已删除。当前环境已通过 repository/Dart structure、dev.90 gate、共享浏览器 Kotlin 编译和 Mihon payload/ABI/classloader/chapter 契约；Flutter/Dart/Gradle/Android SDK/Cargo 仍不可用。

## dev.89 状态

来源浏览器与 Mihon/Venera 请求现在共享来源拥有的 User-Agent 配置和原子 Cookie 快照，但各进程继续维护独立 WebView data directory。详情刷新竞态、2 秒结果图标和插件 IconButton 已完成；synthetic revision 3 与双层真实目录保护已生效。远程详情原先绕过 composition 直接调用来源的第二条更新路径已删除，刷新只能消费经过目录回归检查和持久化的原子快照。新增 app-level Trace 可区分浏览器快照、UA 匹配、`cf_clearance` 是否存在、browse timeout、刷新合并、章节数/synthetic 数量变化和目录回归。当前环境已通过 repository/Dart structure、dev.75–dev.89、共享浏览器 Kotlin、Mihon ABI/classloader/payload/chapter、Venera、Reader/Pipeline/UI、Android dependency/Trace、native header 与本地 libwebp 1.6.0 fixtures；Flutter/Dart/Gradle/Android SDK/Cargo 不可用的项目仍列为未验证。

## dev.88 状态

已在 dev.87 唯一基线上完成来源验证生命周期与详情交互闭环。错误报告中的 Dart 3.12 无关 interface 提升、两个错误 `Stream.toList(growable:)` 和 `reader_runtime` 测试缺少 `ContentKind` 所属依赖均已修复。可见 WebView 由 `network_bridge` 主进程 Activity 持有并通过 activity result 完成；插件隔离进程预先设置 WebView data-directory suffix，浏览器 Cookie/localStorage 通过原子 snapshot 导入 source CookieJar。Cloudflare interceptor 不再后台等待，Mihon cause-chain 投影 typed verification；来源页/详情页等待用户返回后再失效缓存重试。旧 synthetic 单章 revision 已失效。

详情 AppBar 固定地球 WebView、迁移、插件来源设置，加入书架后的本地详情继续注入来源能力；下拉刷新持续显示旋转刷新、绿勾或红叉；分类/标签点击搜索当前来源，长按多选复制。刷新状态、来源 action 与标签选择已按 Presentation 交互所有权拆入 `comic_details_interactions.dart`，主详情文件不再继续堆叠这些局部状态。当前环境通过 repository/Dart structure、dev.75–dev.88、Android dependency、Mihon ABI/classloader/chapter、Venera、Reader/Pipeline/UI、共享浏览器 Kotlin 提取编译和 native header 契约。环境无 Flutter/Dart/Gradle/Android SDK/Cargo，故 analyzer、Dart/Flutter test、APK/kernel 和 Rust 未执行。

## dev.87 状态

已在 dev.86 唯一基线上完成：`Bundle` 导入；Cloudflare verification typed error；来源首页、分页、封面、详情与下载动作的统一 WebView fallback；详情右上角作品网页；来源分类/标签/书架分类分区；条漫 adaptive model v5；持久 promoted artifact 快速恢复。设备 trace 共 7181 条事件，其中 16 次可计时的本地 `content://` artifact cache session-copy 中位吞吐约 5.47 MB/s，同一 5.6–20.0 MB 页面重复恢复，单次约 0.87–4.96 秒；修复删除命中缓存时的重复 CRC 全扫，但未绕过 Pipeline 或建立 App 私有缓存。

当前环境通过 repository/Dart structure、dev.75–dev.87 owner gates、Android dependency、Mihon ABI/classloader/chapter、Venera、Reader/Pipeline/UI、共享 browser Kotlin 提取编译和本地 libwebp 1.6.0 host fixture。环境无 Flutter/Dart/Gradle/Android SDK/Cargo，故 analyzer、Dart/Flutter test、APK/kernel 和 Rust 未执行。

## dev.86 状态

已在 dev.85 唯一基线上补齐详情 WebView callback typedef，关闭用户报告的四处 Dart 类型错误。通用 Android 网络能力已迁入新 `network_bridge`：来源 WebView、Cookie/localStorage 快照、Cloudflare interceptor、Android CookieJar 和 fallback DNS 不再由 `plugin_host_bridge` 拥有；Mihon ABI 只保留 `NetworkHelper` 兼容外壳并 parent-first 消费共享类。旧 plugin-host 登录 Activity、snapshot store、MethodChannel API、metadata reader 网络方法以及 `ExternalPluginController` 的通用网络转发方法已删除；App composition 直接注入 `AndroidNetworkBridge`。 浏览器进程由 App manifest placeholder 选择；主进程读取的 Cookie/localStorage snapshot 使用原子文件交接，未保留跨进程 SharedPreferences。仓库结构、Dart 结构、dev.75–dev.86 门禁、共享浏览器 Kotlin 提取编译、Mihon ABI/classloader/chapter、Venera、Reader/Pipeline/UI 等当前可执行检查通过。当前环境仍无 Flutter/Dart/Android SDK/Gradle，因此 analyzer、Flutter tests 和 APK/kernel 未执行；rhttp 尚未引入。

## dev.85 状态

源码已在本次 dev.84 唯一基线上应用 staged 覆盖并完成后续闭环。Mihon 章节调用失败不再被 synthetic “正文”吞掉；权威空目录在详情显示错误和 WebView/retry，只有 capability 缺失且正文预检非空才生成兼容单章。旧 synthetic 条目由 App composition 使用 `plugin_host` helper 在真实目录恢复后淘汰，Presentation 不解析协议 token。Cloudflare interceptor、256 KiB 数据块、普通文件直接读取和 Android document bridge v4 流式/range 生命周期已接入既有 DownloadSession/Pipeline。当前环境静态/宿主契约已通过；无 Flutter/Dart/Android Gradle/Rust 工具链，因此 analyzer、Dart/Flutter tests、kernel/APK 和真机性能仍未验证。

## dev.84 状态

源码已关闭 dev.83 对 Mihon 图片“全部可宿主直连”的错误假设，并按 source client 能力保留 JMComic 等扩展响应转译，并通过 transport revision 使旧未转译 artifact 失效。组合目录、详情元数据、按 token/source revision 复用持久 page list 的页数投影和详情交互已迁移；当前环境仍无 Flutter/Dart/Gradle/Rust 工具链，真实 analyzer、Flutter tests、Android build 与设备验证尚未完成。

## dev.83 状态

源码已修复 dev.82 的 compile closure、source-specific preload profile、非持久 adaptive 和 stitched 分数像素边缘。VibeVenera model v4 的 metadata/category/language/tag-weight/softmax 与两样本规则已迁入，manifest `animatedHint` 不再冒充实际动画证据。工作树及完整 ZIP 解压副本已通过 dev.75–dev.83、Reader/Pipeline/UI、Android、Mihon、Venera、native header 和本地 libwebp 1.6.0 契约。当前容器无 Flutter/Dart/Rust/Gradle 工具链，因此真实 analyzer、Flutter tests、kernel snapshot、Android build 与真机接缝/预取验证仍未完成。

## dev.82：动画源网格、帧消费推进与 Trace 聚合

- 已修复代码中可确认的两条根因：ANMF 子矩形独立缩放导致的条带错位，以及下载完成后 source revision 停止增长导致的动画推进停滞。
- source chunk 调度与 `bytesCommitted` telemetry 均按 64 KiB 边界聚合；Trace raw ring 默认 10000，保留权威终态和错误。
- 三个 downloads 测试的关闭死锁和 Reader 几何精确 double 断言已修正，未增加固定 pump、真实 socket 或 lazy child 断言。
- 工作树与完整 ZIP 的系统 `unzip` 副本均通过结构、dev.75–dev.82、Reader/Pipeline/UI、Android Trace、Mihon ABI、Venera response header、native header 与本地 libwebp 1.6.0 host fixtures；工作树完整 Android/Mihon/Venera 契约也已通过。
- 当前环境没有 Flutter/Dart SDK、Cargo/rustc 与 Gradle wrapper；不能声明真实 tests、Rust 编译、APK 或真机问题已经验证通过。

## dev.81：Mihon 宿主流式、上传竞态与章节即时入场

- Mihon `resolveResource` 现在返回最终 URL、headers、GET、null body 与 `requiresRuntimeTransform=false`。宿主 transport 首选直接流式请求；失败后刷新 plan，再失败才调用插件 complete-byte fallback。
- `DownloadSnapshot.networkStartLength` 由 DownloadSession 在 restore/queue/acquireWriter/reset/evict 生命周期维护；transfer publisher 不再保存第二套 guessed baseline。
- `UploadSession` 统计 active uploads，延迟 release；revision/cancel 已变化时，任何上传 `Failure` 或对象异常均转为 cancelled，不更新当前 failure/state。
- Local/remote 详情页传入 chapter loader；App 立即 push `DeferredReaderRoute`，后台准备章节并在同一路由替换为真实 Reader。
- `ReaderVerticalGeometry` 持有连续页 extent/bounds/anchor；原来依赖 lazy child 和固定 offset 的两个 Widget 测试已删除。downloads transport 与 App artwork gateway 测试改为 controlled source/stream；Reader 双击使用注入单调时钟，不再 `pumpAndSettle` 或等待固定 400ms。
- Android Trace export 改用 `startActivityForResult` 兼容 `FlutterActivity`；普通图与 WebP viewport 均居中。
- 当前环境的 dev.75–dev.81、Reader/Pipeline/UI、Android、Mihon/Venera 与 native header 静态/宿主契约已通过。当前环境无 Flutter/Dart SDK、Cargo/rustc 与 Gradle wrapper，真实 analyzer/Dart/Flutter/APK 测试仍需外部复验。

## dev.80：增量流式、统一栅格与 Trace 平台导出

- `IngressSnap` 增加单调 revision；DownloadSession 在每次 source lifecycle 变化通知，LiveCoordinator 按 DecodeId 去重并排空活跃 decode 期间到达的新 revision。source revision map 会随 demand detach/会话关闭释放。
- 未知 Content-Length 的当前页进度依据 committed bytes 投影 connecting/receiving；不伪造百分比。
- 新增 `AlignedRasterSize`，Dart 与 native WebP 使用同一整数 aspect-error 比较和 8 像素对齐 fixture。`DecodeTarget.fit`、static `ResizeImage` 与 Rust decoder 不再各自独立决定 X/Y。
- `MediaAspectViewport` 是普通图片、GIF、完整 WebP 与 Pipeline surface 的唯一 fit owner。直接文件图片在尺寸尚未知时继续使用 contain/fitWidth，而不是 fill；WebP output buffer 不覆盖 header 尺寸；prefix 读取排空同步期间新增长度。
- Android Trace 文件保存迁移到 App MethodChannel + SAF `CreateDocument`；Debug 页面只调用注入 facade。复制限制为 64 KiB UTF-8 raw JSONL，并显式报告截断/错误。
- 新增 source revision drain、raster parity、未知尺寸 fit、transfer phase 和 Trace copy/export 回归，以及 ADR 0064/dev.80 静态门禁。
- 用户提供的 libwebp 1.6.0 已通过 host incremental、first-frame-before-complete、blend 与 finite-loop smoke。当前环境没有 Flutter/Dart SDK、Cargo/rustc 或 Android Gradle wrapper，相关 analyzer/test/build 和真机行为仍未验证。

## dev.79：插件、封面与 Reader 流式稳定性恢复

- Venera source operation 由 `plugin_host` 强制单 in-flight；Mihon 继续使用配置并发。删除 Venera WebView 的 raw `loadInfo` promise/object cache，避免与 `resource_cache/catalog` 形成第二详情缓存和跨调用临时对象生命周期。
- Home/迁移封面的 source-owned locator 判断从 HTTP(S) 扩展到任意 absolute scheme；`mihon:resource:` 等 custom locator 可经 `ComicSourceResourceGateway` 正确回源。`ResourceCacheManager` 新增完整 encoded-image resolution in-flight 合并。
- DownloadSession source listener 覆盖 ready、每次增长、seal 和 failure，并对晚接入 ready source 立即投影。`needMoreData` cursor 可由后续 chunk 重新调度；最终 seal 也会唤醒解析。
- DecodeSession 将 ingress/source/cursor failure 设为权威失败，LiveCoordinator 唤醒 Upload output，页面不再因错误永久 loading。空 holder 的稳定 identity 重入仍重建 cursor，不永久保活所有资源。
- 连续阅读未知 extent 与 currentIndex 解耦；异步尺寸变化只在 idle 时保持顶部页像素锚点，滚动事件取消待恢复 anchor。
- runtime/header 确认动画后，自适应 profile 使用分页方向覆盖 source vertical hint；显式漫画方向覆盖不被改写。
- 新增 dev.79 审计、ADR/静态门禁和 owner-package 回归。用户提供的 libwebp 1.6.0 本地源码已通过 host incremental/loop fixtures。
- 当前环境没有 Flutter/Dart SDK、Cargo/rustc 或 Android Gradle wrapper；analyzer、Dart/Flutter tests、Rust tests、APK/kernel snapshot 和真机行为仍需复验。

## dev.78：Reader 等比输出、页面重入与原始 Trace

- 修复 `pipeline_media_runtime.dart` 漏导入 domain `RendererKind` 与 `UploadRegistry` 越权引用 `PlaybackState` 的编译闭包；Registry 改为只问 session-owned `playbackRunning`。
- native WebP 将 DecodeId 尺寸改为最大边界，按源 canvas 等比 fit 且不放大小图；decoded/output/Android texture 使用实际尺寸，同 identity 尺寸变化会失败并退休 slot。
- `DecodeSession` 在 holder 已空且 demand detach 后的下一次进入重建 cursor，修复静态/有限动画滑出窗口再返回只剩 loading；普通 EOF 和有限 loop 语义未改。
- 删除详情页对所有未知页数章节的正文 preflight；未知页数继续显示待加载，目标打开/下载才解析正文。目标 manifest 写入后不再同步全库 reload，已读写入改由统一导航 owner 非阻塞提交。
- Debug Trace 在 dev.78 增加独立有界 export ring；其当时“不合并 raw”规则已由 dev.97/ADR 0081 的有界高频摘要取代。复制、文件导出和会话过滤仍使用该诊断 ring，保存失败不静默。
- 新增 decode replay、fitted upload、无 page-count preflight、raw copy/export Widget 回归与 dev.78 静态门禁。既定 Pipeline 窗口和 lane 未修改。
- 当前环境没有 Flutter/Dart SDK、Cargo 与 Android Gradle wrapper；相关 analyzer/测试/build 必须在具备工具链的环境复验。

## dev.77：Pipeline 媒体运行时原子迁移

- 新增 `PipelineMediaRuntimeFactory`/`PipelineMediaRuntime` 原子能力和 `pipeline_native` 平台 composition package；App 注入，Pipeline session 创建并关闭，核心不反向依赖 bridge。
- `PipelineReaderSession` 真实接线 SourcePool、DecodeRegistry、UploadRegistry、FrameBudgeter 与 LiveCoordinator；策略窗口和 5/3/2 lane 未修改。
- 删除 `PipelinePageStream.source`。Reader/local media 只消费 transfer stream 与 `PipelinePageOutputStream` opaque surface，不取得 `DecodeId`、mutable source、cursor、output claim、textureId 或 native handle。
- Reader WebP 页面不再创建 `NativeWebpPlayer` streaming cursor/texture；App 演示调用方和测试同步迁移，没有保留旧命名兼容参数。
- 暂停/倍速与动画 due-frame 推进进入 Pipeline；UploadSession 按 command freeze/resume/rescale。viewport 播放门只绑定 current/transition upload identity，不为纯预解码页创建 upload session；ticker 仅在存在 running timer 时运行。
- Android texture 按 DecodeId 复用并采用 claim-safe retirement：旧 surface 在 replacement 期间有效，最后一个 frame owner 释放后销毁 lease；runtime close 等待 retired lease drain。
- 新增 runtime ownership、upload retirement 与 composition smoke 回归，以及 dev.77 静态所有权门禁。用户提供的 libwebp 1.6.0 已在本地源码构建并通过增量/loop fixtures。
- 当前环境仍无 Flutter/Dart SDK 和 Android Gradle wrapper，analyzer、Widget/package tests 与 APK/kernel snapshot 未执行；静态门禁不能替代这些验证。
- 非 WebP complete-artifact Flutter decode 仍是已记录的下一阶段格式统一问题；dev.77 只声明 WebP Reader streaming 链已原子收回。

## dev.76：Reader 页面加载所有权与立即退出审计

- Reader 删除 viewport 固定居中加载圈、页面 ready 集合和首帧触发的全屏 overlay 重建；连续纵向页面只保留具体图片区域内的加载反馈。
- `LocalImagePlayer` 删除 `showLoadingIndicator` 兼容开关，页面 loading/ready/invalid 状态不再由 Reader 与媒体组件双重拥有。
- dev.76 当时记录的 `PipelinePageStream.source -> NativeWebpPlayer` 债务已由 dev.77 / ADR 0061 原子关闭；该历史项不得作为恢复直接 source/cursor 路径的依据。
- `_ReaderPageHost` 继续去重首帧回调并记录 telemetry，不参与可见 loading 状态。
- 设备 trace 无 exception；7 个页面 demand 在退出时全部 detach，`receivingRetained=false`，未见退出后继续收包或 Reader 越权关闭 session 的证据。当前页 WebP 在 partial/full artifact 阶段有两次 decode start，退出前未记录首帧，列为真机后续验证而非通过缩窗处理。
- 全仓其他固定居中圈均属于封面内容、详情/设置/演示路由初始化或具体媒体页面；Reader controls 只保留局部下载按钮工作态和只读 Pipeline 进度。
- 新增 local-media owner Widget 测试、Reader 无全局圈测试、dev.76 静态门禁、审计文档和 ADR 0060。Pipeline 7/3、2/1、current/transition、5/3/2 未修改。
- 当前执行环境没有 Flutter/Dart SDK；静态/结构门禁可执行，analyzer、Flutter test 与 Android build 必须在具备 SDK 的环境复验。

## dev.75：编译闭包与契约归属

- 用户报告的 `EncodedResourceSource`、AssetBundleTransport、Reader preference extension、ComicManifest、readerPageDownloadId 与 Coverage const 错误均已修复。
- 删除无生产调用的 `ComicDetailsScreen`、App `asset_bundle_transport.dart` 和 Reader runtime 对该内部 transport 的兼容转出。
- `AssetBundleTransport` 测试迁入 `pipeline_runtime`；download identity 契约保留在 `downloads` owner。
- App 详情测试直接使用 `LocalComicDetailsScreen`，不再维护第二套详情生命周期和 byte-only cover API。
- Architecture 文档修正旧的 `reader_runtime` session composition 描述：资源会话归 `pipeline_runtime`，Reader runtime 只做 Presentation/observation adapter。
- 新增后续迭代提示词与 dev.75 ownership gate；补齐 `pipeline_runtime`、`reader_runtime`、`local_media_ui` 的 analyzer/Flutter test runner 覆盖，为 `local_media_ui` 增加 composition 编译 smoke test，并移除 check 脚本中的自动格式化。Pipeline 网络、预下载、解码和上传策略未修改。

## dev.74：纵向几何与诊断可用性闭环

- `local_media_ui` library 指令顺序编译阻断已修复。
- 运行时尺寸比例、无缝拼接、保存页直接定位和视口锚点已统一。
- 来源页/详情页封面改为持久文件 source；稳定 artwork revision 与图片签名验证避免重复下载和坏缓存。
- Debug Trace 支持 burst 合并、筛选、强调色、复制和 JSONL 导出，并摘要 Venera/Mihon opaque identity。
- 未改变 Pipeline 的 7/3 下载、2/1 预解码、current/transition 上传和 5/3/2 lane。

## dev.73：Pipeline 构造闭包与 UI 依赖收口

- 修复 dev.72 新包遗漏的 11 个编译错误，补齐 profile import、SourceFactory 注入、page stream 内容类型投影、权威 ingress source 读取与 Reader 尺寸回调。
- `pipeline_runtime` 不再依赖 `bridge`；NativeSourceFactory 由 `local_media_ui` 默认组合提供。
- `local_media_ui` 通过不可变 `PipelineReaderSessionFactory` 派生页面 loader，页面 identity 来自 `PipelinePageStream`，不再依赖 downloads 实现。
- 静态 demo 与 Widget 测试显式传入 Pipeline factory；Pipeline host 不再拥有隐式默认平台实现。
- 新增编译边界门禁并更新现有 UI/repository 门禁以验证新所有权。
- 本轮未修改 Venera transport、预下载/预解码窗口、lane 或进度策略；用户反馈的设备上行流量暂时正常。

## dev.72：Pipeline 运行时所有权与共享请求方案

- `pipeline_runtime` 成为 Reader 资源会话的组合所有者，持有下载、artifact、SourcePool、解码/上传调度、进度与关闭顺序。
- Reader 仅报告 viewport observation 并读取只读页面流；当前页进度由 Pipeline 从 observation 选择，不存在 Reader→下载状态的独立控制入口。
- `local_media_ui` 只消费 `PipelinePageStream`，不再依赖 `DownloadSession`。
- Home、来源浏览和详情页封面共用 source request-plan transport 与 response cache；Venera thumbnail/page resolver 分流。
- source request-plan 对同 locator 并发合并并有界缓存，普通正文流式进入既有 artifact；VibeVenera 的 7/3、2/1、5/3/2 策略保持不变。
- 当前环境无 Flutter/Dart SDK，需在 Android/Flutter 环境继续以真实 Tx/Rx 计数验证上行异常；本版本只声明已消除代码中可确认的重复插件配置与封面正文路径，不声明设备流量已实测正常。

## dev.71：来源资源原子绑定与 Home 组合解耦

- `ChapterResourceAccess` 原子携带 streaming response transport 与 complete-byte transform fallback；`PersistentChapterDownloadService` 只读取一个绑定快照。
- `ComicSourceResourceGateway` 成为 App 中唯一 source-private resource composition owner，统一来源解析、旧 Venera locator 拒绝、transport pool、Reader loader 与章节下载绑定。
- `DemoHome` 不再直接访问 `ExternalPluginResourceTransportPool`，也不再通过两个独立 setter 配置下载服务。
- gateway close 先解绑仍存活的下载服务，再关闭其 transports；第三方旧 capability 保持兼容，但生产路径优先使用原子 capability。
- source compatibility 动作改为 `_DemoHomeState` extension，移除全局函数对整个 State 的传递。
- 新增 source-resource atomic binding 静态门禁、下载流式优先测试和 gateway 生命周期测试。

## dev.70：VibeVenera 风格 request-plan / streaming-body 分离

- Venera source runtime 只负责 `onImageLoad`/`onLoadFailed` 及 Cookie/header/request-plan 解析；普通图片 body 由 composition-owned `ExternalPluginResourceTransportPool` 使用 Dart `HttpClient` 直接流入 DownloadSession。
- request-plan 与 body 所有权分离后，Reader、持久章节下载和整本队列复用同一 response-loader/transport/artifact 边界；需要 `onResponse`/`modifyImage` 的来源才使用完整 runtime fallback。
- 稳定资源窗口为下载 +7/-3、预解码 +2/-1、上传 current/transition；lane 为 network/decode/upload 5/3/2。普通来源继续使用标准 profile。
- 正常 role-window detach 不取消 receiving 连接；显式 cancel/dispose 通过 Stream subscription 取消 response。错误响应直接 abort，不为重试读取完整错误 body。
- ChapterDownloadSnapshot 使用 completed pages + 当前页 chunk fraction，80ms 合并发布；Reader 只显示 queued/receiving，promoted/sealed/restore 隐藏。
- trace 构造时递归摘要 Venera locator，避免 Debug trace 被完整 Base64 identity 淹没。

## dev.69：Venera 原生字节与稳定连续 Reader

- 完成 dev.65–68 回归审计，明确区分 locator、图片正文传输、取消、pipeline 重提和连续布局锚点五条链路。
- Venera 普通图片正文走原生二进制 token，不经 WebView Base64；动态响应变换仍保留受限兼容路径。
- Venera requestId 绑定原生连接，取消会真实终止连接；默认串行、仅当前页，GET/HEAD 无请求体。
- Pipeline 不重复提交未变化的 role window。
- 纵向拼接三态继承、无 separator、1px 覆盖；媒体/viewport 重排保留可视锚点，拖动期间不跳转。
- Reader viewport 当时单一拥有 loading indicator；该设计已被 dev.76 / ADR 0060 的页面媒体所有权取代。持续失败的 lazy separator 测试断言已实际修复。

## dev.68：Venera 入口预检、请求止损与无缝连续布局

远程详情页是否要求普通内容刷新，不再决定 locator 兼容性。`_openImportedChapter`、单章下载和整本下载在任何路径上看到 `venera-resource://` 都会通过显式 `RefreshableChapterComicSource` 获取新章节；若来源仍返回旧 locator，则在 Reader/Pipeline/DownloadSession 建立前失败。

App 的 source-resource loader 与 `plugin_host` runtime adapter 都拒绝旧 Venera token，后者在创建 runtime invocation 前执行，因此未来即使新增调用方漏掉预检，也不会形成插件请求风暴。Reader 对 `venera-resource:` 章节采用当前页 + 下一页、最多两个 download demands 且不自动重试的保守窗口；普通 HTTP/file 章节维持原策略。

纵向拼接使用无 separator 的 `ListView.builder`。只有非拼接模式创建 8px gap；未知活动页的临时高度至少等于 viewport，使页面媒体自己的加载圈位于当前可视区域内。真实媒体尺寸仍从来源元数据或同一份媒体载荷回传；拼接时静态图、Flutter 动图和 native texture 统一按宽度贴合，完整显示、不裁切。

## dev.67：Reader 控制所有权收口与组合解耦

顶部控制栏不再拥有页面导航或布局选择。页面位置、跳页和 RTL 镜像由底部 Slider 与 Reader 手势统一承载；方向、纵向拼接和自适应只从全局/每漫画设置进入 Reader composition。`ReaderRuntimeScreen` 删除任意 action Widget 注入，本地文件 Reader 也不再直接调用 `ReaderController.requestPage`。

顶部扩展从任意 Widget builder 窄化为 `pageSubtitleBuilder(PageAsset) -> String`。runtime 负责统一绘制章节标题和只读副标题，因此调用方不能再次放入页码、导航按钮、菜单或新的状态所有者。对应的本地文件页码、上一页、下一页、选页 key 与旧兼容别名已删除。

`ReaderSessionSettings`、`AdaptiveReaderProfile` 和分类函数迁入 `reader_session_settings.dart`；`reader_runtime_screen.dart` 从 1600 余行降至 1500 行预算以内。仓库门禁同时拒绝 `ReaderAppBarActionsBuilder`、`appBarActionsBuilder`、旧标题 Widget builder 和顶部方向菜单重新出现。

旧 Venera locator 刷新显式绑定 `RefreshableChapterComicSource`，不再依赖 Dart 对无继承关系接口的交叉类型提升。纵向导航只在目标连续页完成懒构建、进入视口并发布 observation 后 acknowledge；回归测试等待目标语义 identity，而不是固定 pump 次数。

## dev.66：Venera 代际刷新、实测拼接与控制命令恢复

- Venera durable locator 恢复函数显式接收 source，修复 dev.65 所有新 locator 都会触发 `source is not defined` 的产品回归。
- `CachedBrowsableComicSource` 的章节元数据使用新的 schema revision；App 在打开和下载前识别持久化 legacy token，失效旧缓存并重新加载章节。
- Venera runtime 记忆同一 locator 的已解析图片配置并合并并发 `onImageLoad`；Dart adapter 合并并发的同 URI runtime 调用，完成后立即释放，不建立新的页面字节缓存。
- Reader runtime 接收媒体实际宽高。静态格式读取当前字节头，WebP 复用已有容器信息；连续列表按真实比例重排，拼接仅控制 separator，不裁切内容。
- ReaderView 的方向切换和页码命令等待 ScrollPosition 完成 dimensions，再 jump、acknowledge 并发布 observation；顶部页码、前后翻页和布局切换恢复工作。

## 0.31.0-dev.65：持久插件资源与每漫画 Reader 设置

- Mihon bridge 补齐 `java.util.Locale` 导入，恢复 Android Kotlin 编译闭环。
- Venera 章节页 locator 携带受约束的版本化 image/comic/episode identity，不依赖 WebView generation 内的 token map；来源运行时重建后仍延迟执行 `onImageLoad`。legacy token 继续可读，但新章节不再生成它。
- `DebugTraceLog` 对 enabled/record/clear 使用单帧合并通知，修复 Reader page host build 中同步触发 `AnimatedBuilder.markNeedsBuild`。
- 阅读设置新增全局自适应布局与纵向拼接。每漫画覆盖按 `sourceId + comicId` 存入小型 App preference map，最多 512 项；设置只投影 Reader 方向/拼接/自适应，不持有页面、下载或缓存。
- 自适应分类依据动画提示、页面宽高分布与来源方向，只有置信度至少 0.6 才覆盖既有来源/进度模式。Animated WebP 优先保持分页，长图高占比选择纵向。
- 纵向 Reader 由竖直分页改为按页面比例的连续列表；纵向拼接只把页间距设为零。RTL 页码 slider 和左右端点标签随阅读方向镜像。

## 0.31.0-dev.64：第四页杂项与设置所有权闭环

- 修复 dev.63 的两个 Dart 编译阻断：下载服务通过显式 `ConfigurableChapterResourceLoader` 能力绑定注入 source loader；Mihon 分组测试使用显式 Map 下标闭包。
- 根导航新增第四页“杂项”，包含主题/沉浸/trace 快捷设置、下载管理、导入、设置、关于和 Debug trace。
- 设置根页包含数据、网络、书架、阅读、下载、外观。主题和书架默认值持久化；Reader 新章节默认模式/沉浸值进入既有 Reader；网络/供电/并发调用持久整本下载队列。
- 数据页显示 storage-derived 目录，导出 catalog 元数据备份，并通过统一缓存协调器 inspect/clear。目录变更仍受迁移协议门禁，不提供危险的字符串替换。
- `DebugTraceLog` 作为最多 500 条事件的观察投影接入 startup 与 Reader trace；关闭记录、清空或复制均不改变生产策略。
- App 偏好控制器不导入 `dart:io`，持久 map 读写由 `storage_bridge` composition 注入。

## 0.31.0-dev.63：插件资源传输与媒体/章节兼容闭环

- 页面稳定 identity 与资源定位分离：章节内允许重复 URI，唯一性只由非空 `pageId` 保证。该规则与 Reader、下载和持久进度使用的 stable identity 一致。
- 持久章节下载在 `downloads` 内选择 transport。普通 file/http(s) 继续使用 `IoTransport`；Mihon/Venera 私有 URI 通过 composition 注入的 `ChapterResourceLoader` 调用对应 `BrowsableComicSource.loadResource`，详情页不拥有网络或下载分流。
- Reader 的同步 session snapshot 不再在 Widget build 中直接更新 transfer notifier；同一帧内只保留最新进度并在 post-frame 发布。
- Venera 与 Mihon 页面输出 WebP/GIF 等内容提示，Venera 默认补浏览器 UA 并使用逐跳 Cookie 的 8 跳有限重定向；媒体字节嗅探仍为最终格式判定。
- Mihon 封面统一为保留 source headers 的 opaque resource。该版本曾让详情页并发预检未知章节页数；普通章节预检已由 dev.78 / ADR 0062 删除，只有 synthetic gallery 非空验证保留。
- Mihon gallery 兜底允许在目录 API 报错或返回空时继续做 synthetic page preflight；只有非空正文可进入协议，目录与正文都失败时返回包含原始目录根因的诊断。

## 0.31.0-dev.62：漫画源管理投影与 Mihon 章节结果闭环

- 漫画源管理只投影已启用来源，固定按原生、Mihon、Venera 三段排列并使用分隔线。Mihon language family 在该投影中选择当前 locale、通用语言、英语或其他语言作为默认项，剩余来源默认折叠。
- Mihon/Venera 安装管理分别采用顶部“已安装/仓库”页签，不再把标题和内容切成左右两栏。Mihon 设备扩展发现、刷新、导入与错误只属于已安装页；仓库页仅负责索引、安装和更新。
- 来源顺序仍持久化：普通来源在各自生态内拖动，Mihon 语言 family 作为一个可排序单元。
- Mihon `unwrapAsync` 兼容 Future、RxJava 1 BlockingObservable/BlockingSingle 与 RxJava 2/3 blocking API。章节/页面候选出现真实错误时会聚合并返回，不会因另一路径返回空列表而生成“正文”。
- synthetic gallery 只有在真实章节目录完整为空、并且 synthetic 章节实际得到非空页面后才进入协议；详情直接携带验证后的页数。远程目录中 pageCount=0 被解释为未知而非实际 0 页。

## 0.31.0-dev.61：UI composition ownership 与外部仓库信息架构

### 已完成

- 当时新增 `reader_runtime` package 以承接 Reader session composition；该资源所有权已在 dev.72 迁移到 `pipeline_runtime`。当前 `reader_runtime` 只保留 Presentation/observation adapter，App facade 只转出仍被应用使用的 Reader API。
- 新增 `local_media_ui` package，将原 `webp_demo.dart` 按职责拆分，并从 `media` 显式导入 WebP prefix parser。App 的生产依赖不再直接包含 `pipeline`、`sessions`、`storage`、`transport`、`texture_bridge`。
- 外部插件管理从主来源列表中移出安装记录；Mihon/Venera 各自在生态页面左栏显示已安装，右栏显示仓库。安装、更新、移除和 activation failure 仍由 `ExternalPluginController` 所有。
- dev.61 的“仓库语言折叠”已由 dev.62 废弃；语言折叠只存在于漫画源管理的已启用 Mihon 来源投影。
- 新增 `external_plugin_repository_model_test.dart` 与 `tool/test_ui_architecture_contract.py`，并更新 repository checker 对新 package 边界的要求。

### 保持不变

- Reader demand、download/artifact、decode 与 cache 所有权未移入 Presentation。
- 外部插件仍在独立 runtime process 执行，仓库 UI 不获得 payload 或 session 所有权。
- dev.60 的异步书架恢复、Venera 登录、Mihon 章节探测与 WebP 增量播放语义保持不变。

## 0.31.0-dev.60：Venera 登录与增量 Reader 主线

- Venera `account` 已进入统一 `AuthenticatableComicSource`：支持凭据、按字段顺序 Cookie、WebView 最终 URL/标题/Cookie/localStorage 快照、退出与登录状态；设置页提供对应入口，runtime 继续持有来源数据与回调执行权。
- Mihon 章节目录解析改为多候选、多方法探测。组合详情缺少章节不会触发提前单章化；真实列表为空或某个兼容方法 unsupported 时继续尝试独立目录接口，只有所有候选结束后仍为空才生成 gallery 单章节。
- App 首页不再等待 durable composition。内存 composition 先提供可操作 UI，持久书架在后台恢复并以顶部细同步条提示；恢复完成后原位切换服务。
- Reader 在 scale=1 时不安装缩放 recognizer，远程 PageView 横向滑动恢复；动画播放控件只对声明/探测为动画的页面显示。
- 远程 WebP native cursor 直接消费 DownloadSession 的增量 source，并处理 `needMoreData`。顶部 transfer 指示分离已恢复前缀和当前网络新增字节，不复制下载或 artifact 所有权。
- runtime worker 协议回归已覆盖 settings 与 account 扩展操作；错误报告中的夹具缺口已修复为真实调用覆盖。

## 0.31.0-dev.59：Mihon 章节目录身份与 Venera 插件设置闭环

- 严格以用户上传的 `zic_v0.31.0-dev.58_fixed.zip` 为唯一基线。未合并此前 dev.58 归档或其他历史候选。
- Mihon 详情页保留插件返回的完整多章节目录，不再由单章节兼容路径覆盖。仅当真实章节列表为空时生成一个带显式 `synthetic` 标记的“正文”章节；非空目录不会调用 synthetic factory。
- Mihon runtime 在详情加载后按 opaque chapter ID 保存原始 `SChapter` 对象，阅读时优先复用，避免重建丢失扩展私有/运行期状态。runtime 重启或缓存缺失时重新拉取来源目录，并按 URL，或名称、章节号、汉化组和发布时间组合精确匹配；缺失和歧义均明确失败。
- 1.4 与 1.6 兼容 `HttpSource.fetchChapterList` 均重新执行扩展的 `prepareNewChapter(chapter, manga)`，确保多章节 URL、编号和来源自定义归一化在进入 ZIC 协议前完成。
- Venera runtime 新增 `loadSourceSettings`/`updateSourceSetting` 完整实现，映射 `switch`、`text/input`、`select`、`multiSelect` 与 `callback/action`；设置值使用类型保持的私有持久化，兼容 dev.58 的字符串布尔/数组旧值。
- 漫画源管理页现在为 Mihon 与 Venera 的 `ConfigurableComicSource` 都显示设置入口。Venera 不显示 Mihon Web 登录项；动作设置在用户显式点击期间可执行来源确认对话框中的非取消回调，并在页面反馈执行结果。
- 新增多章节不降级、章节稳定身份、双 ABI `prepareNewChapter`、Venera 官方形态设置枚举/持久化/动作回调、通用 adapter action kind 与依赖门禁回归。

## 0.31.0-dev.58：Mihon 分版本 ABI 隔离与 Venera 运行语义闭环

- Mihon 1.4 与 1.6 `extensions-lib` 不再进入 App runtime classpath。Gradle 在构建时分别解析上游固定 revision、提取 `classes.jar`、使用 Android D8 生成 dex asset，并写入长度/SHA-256 manifest；1.5 metadata 显式映射到兼容的 1.6 asset。
- activation 按 `extensionLib` 选择 ABI，并把扩展 APK 与对应 ABI jar 交给 child-first `MihonExtensionClassLoader`。`eu.kanade.tachiyomi.*` 只从插件 workspace 加载；AndroidX Preference 与 OkHttp/Injekt/协程等 common runtime 仍由隔离宿主进程单一提供并合并资源，修复旧 e-hentai 扩展覆盖 1.6 final `HttpSource` 方法的 verifier 失败。
- 两份动态代码文件都按 Android 14 要求在写入前标为只读、写后 `fsync`、长度/SHA-256 重验并原子提升。activation 分别预检 child plugin ABI 与 parent common runtime，不再把 API 版本冲突误报为入口构造失败。
- Venera 不再把宿主 bootstrap 的 strict directive 强加给来源脚本，并提供兼容的全局 `res` scratch binding；详情加载错误现在携带 operation 与受限 JS stack，便于定位真实源脚本。
- Venera 默认调用上限从 10 秒调整为 55 秒，为底层单次 15 秒连接 + 30 秒读取预算保留 10 秒桥接/脚本收尾余量，且仍低于 60 秒平台上限；超时会继续协作取消，并显示操作名与实际上限。
- 新增 Mihon ABI 路由/child-first、Gradle 双 ABI 资产闭包与故障注入、Venera legacy `res` 详情及 55 秒默认限制回归。

## 0.31.0-dev.57：只读 Mihon dex 与 Venera 分页/资源兼容闭环

- 修复 Android 14+ 拒绝从可写 APK 加载 dex：Mihon payload 先打开同目录 `.part` 的写入句柄，立即将路径设为只读，再通过已打开句柄复制、`fsync`、完成长度/SHA-256 重验并原子提升为 runtime `extension.apk`；类加载前再次确认只读，失败仍由 activation workspace 统一清理。
- 修复 `VeneraRuntimeDriver` 响应头泛型编译错误。响应适配改为接受 `Map<*, *>` 并逐项净化 String key 与可迭代值，同时兼容 `HttpURLConnection.headerFields` 的 nullable 泛型和 OkHttp 的非空 multimap。
- Venera browse 能力现在把 `load` 与 `loadNext` 都视为正式 loader。token 分页由隔离 runtime 按 source/query/options 保存，支持官方 e-hentai 等 `{comics, next}` 契约，不再在 activation 阶段误报无 browse capability。
- Venera 封面 URI 归一化为绝对 HTTP(S) 地址，普通封面可直接进入同一受控 Network/Cookie/response-limit/图片转换链；章节页面继续使用有生命周期的 `venera-resource://` token，不改变 Reader 或缓存所有权。
- Venera 详情和章节统一输出领域值 `vertical`；Dart adapter 同时接受旧 `topToBottom`、`webtoon`、左右方向长名与规范枚举，未知值仍明确失败。
- Venera source-key 静态检查只读取 `class ... extends ComicSource` 后的第一个类级 `key = "..."`，不再把 Picacg 方法内的 `let key` 等局部变量误判为冲突 metadata。
- 新增产品源码提取式 Kotlin/JavaScript 门禁：nullable/non-null response header 编译、Mihon APK 只读权限、Venera `loadNext` 两页推进、绝对封面资源、方向别名与方法局部 key 回归。

## 0.31.0-dev.56：Mihon payload Context 与 Venera 当前源兼容闭环

- 严格以 dev.55 为基线，并将用户提供的 `git_latest_two_commits.zip` 中 13 个对应文件原样覆盖后继续开发；保留其“读取设备已安装 Mihon 扩展”、Venera gzip/deflate 响应解码、扩展索引/UI 与生成 Android host 升级。
- Mihon activation 现在为 process-private APK 构建 payload 专属 `Context`：包名、`ApplicationInfo`、资源、assets、class loader、theme、LayoutInflater、偏好与文件/cache 目录均绑定到该扩展副本。运行时重新核对 APK 包名和 1.4/1.5/1.6 ABI，避免扩展资源或隔离存储错误表现为泛化 `activationFailed`。
- Mihon 入口兼容 Kotlin `object`、静态 `create/newInstance/getInstance` 工厂、`Context` 构造器和无参构造器；每个入口失败均携带具体类名与根因。Dart `ExternalPluginActivationException` 也保留 native cause，产品 UI 可直接展示可定位诊断。
- Venera browse 兼容当前 `explore` 数组/对象/`Map`、直接 loader，以及 `category.parts[].itemType/categories/categoryParams` 与旧 `target.attributes` 两类分类契约；动态 `optionLoader` 和静态 `optionList` 都转换为真实默认参数，不再仅因对象 key 存在却未识别容器而报告“no browse capability”。
- Venera 网络桥将 `Accept-Encoding` 收敛到宿主实际解码的 gzip/deflate，并继续按 `Content-Encoding` 有界解压。公共域名被系统 DNS 异常解析为空或回环/私网地址时，独立进程可通过受限 DNS-over-HTTPS 获取 A/AAAA 地址，再由 OkHttp 自定义 DNS 保留原域名 TLS/SNI；CNAME、回环、链路本地、私网和组播答案均拒绝。
- 新增从实际 Kotlin/JavaScript 产品源码提取并执行的 Mihon 入口构造、payload Context 编译、Venera 网络策略和 Venera bootstrap 合约门禁，以及 activation cause、当前分类形态和 DNS 过滤回归。Reader、下载、缓存、session/cancel 和专用 runtime process 所有权不变。

## 0.31.0-dev.55：Mihon 单一 ABI 提供者与 release 保留闭环

- 修复 Android release `checkReleaseDuplicateClasses`：`extensions-lib` 现在只作为非传递的 Mihon/Tachiyomi ABI AAR 使用，不再把其旧 POM 中的 Kohesive Injekt 依赖与当前 Keiyoushi common bundle 同时带入 App。
- 移除重复声明的 `androidx.preference:preference-ktx`。当前 pinned `extensions-lib` AAR 已提供该 ABI；宿主继续只显式提供 Keiyoushi 当前使用的 null2264 Injekt、协程、序列化、网络、解析与 QuickJS 运行库。
- 新增 Android 外部运行时依赖闭包检查，禁止重新引入官方旧 Injekt 或第二份 AndroidX Preference，并要求 `extensions-lib` 始终保持 `transitive = false`。
- 新增 consumer R8 规则，保留动态 APK 会引用但静态 App 图不可见的 Source、Preference、Injekt、RxJava、协程、序列化、OkHttp/Okio、Jsoup 与 QuickJS 二进制 API。
- Mihon activation 在创建 class loader 前预检核心宿主 ABI。缺失 Source/模型、Preference 或 Injekt 时明确拒绝 activation，不再延迟为来源空结果或不稳定反射错误。
- 新增 host ABI 缺失报告回归，并保持独立 runtime process、payload 重验、session/cancel、Reader、下载和缓存所有权不变。

## 0.31.0-dev.54：Android 依赖闭环与 Mihon runtime 清理

- 修复 `ExternalPluginController` 恢复 manifest 时调用不存在的 `File.isFile()` 所造成的 Dart 编译阻断。恢复阶段现在只接受插件私有目录中的普通 `.apk`/`.js` 文件，并拒绝目录、外部路径、符号链接和 `.part` 预览文件。
- `tool/configure_platforms.py` 现在同时配置 Android Internet 权限和宿主级 JitPack 仓库。它优先写入 `dependencyResolutionManagement.repositories`，否则写入生成宿主的 `allprojects.repositories`，兼容 Groovy/Kotlin DSL 且保持幂等；插件子工程也统一使用 canonical `https://jitpack.io`。
- 保持 Keiyoushi 当前 1.6 runtime-only 依赖坐标不变，但确保这些依赖由真正解析 `:app:releaseRuntimeClasspath` 的宿主仓库集合获取，不再依赖插件子工程局部 repository 对最终 App 配置生效。
- Mihon 每次 activation 使用包含 `driverId` 的独立 code-cache workspace，避免同插件同版本并行 activation 相互删除 APK、dex 或 native library。activation 失败立即清理；关闭时协作取消请求、关闭 source，并在真实任务排空后删除 workspace。
- 专用 runtime Service 启动时清理上次进程死亡遗留的 Mihon workspace。请求任务改为预注册的 `FutureTask`，关闭/取消发生在任务启动前也能完成 request result 与清理，不再留下未计数的运行时目录。
- 新增 generated-host Groovy/Kotlin repository 回归、manifest 非法 payload 恢复回归及 Mihon workspace 唯一性/陈旧目录清理回归。Reader、下载、缓存和 Home startup 所有权保持不变。

## 0.31.0-dev.53：Mihon/Venera 真实运行时与产品入口

- `plugin_host_bridge` 在既有 `:zic_plugin_runtime` 进程内注册 Mihon 与 Venera 原生 driver；Dart process host 继续拥有 payload 重验、session、取消、并发、响应上限与关闭策略，Kotlin 不复制这些所有权。
- Mihon APK 从 process-private 已验证副本加载，解析批准的 `Source`/`SourceFactory` 入口并兼容现行 1.6 suspend API 与旧 Rx API；browse/detail/chapter/resource 被映射到共用 protocol v1。图片请求优先复用扩展自己的 client、headers 与拦截器，无 client 时才使用平台 HTTP 后备。
- Venera JavaScript 在无 UI、禁用文件/内容访问和 DOM storage 的 process-private WebView 中运行；实现 1.6 `ComicSource`、Network/Cookie/Convert/Storage/HTML/APP/compute 兼容桥、最低宿主版本检查、数组/对象/`Map` 漫画与章节返回兼容、资源 HTTP 失败重试，以及受像素/响应上限约束的 `Image` 裁剪、旋转、拼接和输出桥。
- 漫画源管理新增 Mihon 仓库与 Venera 源仓库入口。下载、不可变 payload 提升、SHA-256/签名/ABI/source-key 检查、显式信任、安装/更新/回滚/移除及重启恢复由 `ExternalPluginController` 统一管理；启动失败直接显示，不伪装成空源。
- Mihon 仓库入口接受当前 `index.pb` 和 `repo.json`，发现阶段自动使用同仓库的完整 `index.json` companion；catalog 同时解析当前 `extensionList.extensions` v2 对象和旧版数组，不再默认读取仅含升级提示的旧 `index.min.json`。
- 外部源仍只作为普通 `BrowsableComicSource` 注入既有 catalog/cache/download/Reader 管线，不获得导航、Reader demand、页面 artifact 或缓存所有权。Home startup 已有核心服务阶段保持不变，插件恢复放在核心服务 ready 之后。

## 0.31.0-dev.52：Binder service-death generation 与 packet 完整性

- `runtime_service.dart` 与专用 entrypoint 测试显式导入 `catalog`，bridge 测试依赖也直接声明，关闭 `ExternalComicPluginFormat` 编译遗漏。
- Android bound-service client 使用每次绑定唯一 generation 和 Binder `linkToDeath`。旧 Service 的迟到断开/死亡回调不能影响新的显式重绑；服务死亡只失败当前 pending/queued 调用，不自动重放或重激活。
- 如果 Service 尚未连接且全部调用已超时，当前 binding generation 会被废弃并解除绑定，下一次显式 activation 可创建新 generation；已连接进程中的单次请求超时不会拆除无关 session。
- 大响应 packet 使用 canonical root、exact length 与 SHA-256。读取时一次完成文件复制到平台 codec 缓冲和摘要验证，之后立即删除；损坏和路径逃逸均拒绝并清理。
- Home trace、静态/动画图片、Reader demand/artifact 与 process-side activation/session policy 不变。Mihon class-loader driver 与 Venera JavaScript sandbox 仍 fail-closed。

## 0.31.0-dev.51：Android 专用 runtime service 启动与 Binder-safe transport

- 保留用户已确认可编译的 `ExternalComicPluginFormat` import 修复，不再回退或重复修改该问题。
- `plugin_host_bridge` 在 Android manifest 中声明不可导出的 `:zic_plugin_runtime` Service；Service 创建关闭自动插件注册的 FlutterEngine，并执行 App 主库中保留的第二 Dart entrypoint。
- 第二 entrypoint 只装配 `ExternalPluginRuntimeServiceEndpoint` 与 MethodChannel handler。默认 driver 集为空，因此 Mihon/Venera activation 在专用进程中返回 `driver-unavailable`，不会回落到主进程执行。
- 主进程 plugin bridge 使用 lazy bound-service client 转发 activate/invoke/cancel/close。每个请求只有一个 correlation identity；Binder/service 死亡会失败所有活动请求，后续请求必须重新绑定并显式 activation，不自动重放。
- Binder request 限制为 512 KiB。大于内联阈值的 response 使用应用私有、原子提升的 packet 文件传递，host 校验目录与长度后读取并删除；二进制资源不转 base64。服务启动/销毁会清理专用 `.part`/`.packet`，未领取的大响应也有有界保留时间。
- Home trace、图片 codec、Reader artifact 和缓存所有权保持不变。Mihon class-loader driver 与 Venera JavaScript sandbox 仍未实现。

## 0.31.0-dev.50：编译闭环与 runtime service process-generation 所有权

- 修复 process activation 的三处编译阻断：流式 SHA-256 输出使用 `Sink<Digest>`；activation 显式依赖 handshake 所在 channel；测试从 `dart:async` 与 `domain` 引入各自拥有的 `Completer`/`Failure`。
- 新增 `ExternalPluginRuntimeServiceEndpoint`，统一处理 Mihon/Venera activate、invoke、cancel、session close 与 process close。平台 transport 不再拥有 activation/session policy。
- activation 返回新的 `processId`；后续请求必须同时匹配 process/session。服务死亡或重启后，即使 session ID 重复，旧连接也会以 `runtime-process-mismatch` 失败且不重放请求。
- `plugin_host_bridge` 新增 Dart MethodChannel service handler，将稳定错误映射到平台，同时把 payload 重验、私有 staging、driver 创建、session registry 和 shutdown 委托给 process host。
- Home trace、Reader demand/artifact、图片 codec 生命周期保持不变。Mihon `Source`/`SourceFactory` class loader 与 Venera JavaScript engine 仍未实现。

## 0.31.0-dev.49：有效 decode target 回归与隔离进程 payload 所有权

- `Flutter target rebuild keeps the presented frame visible` 不再把任意容器宽度变化当作 codec 必然重建。fixture 通过 VP8X 头声明 2048×2048 画布，测试先证明生成了两个不同 downsample target，再验证替代 codec 完成前旧 `RawImage` 持续可见。
- 新增 `ExternalPluginRuntimeActivationEnvelope`，在隔离进程入口严格解析 Mihon/Venera activation wire、能力和资源限制，拒绝额外字段与格式/插件身份不一致。
- 新增 process-private payload staging：按批准长度流式复制并计算 SHA-256，原子提升后 driver 只接收已验证副本；原始 host 路径后续变化不会影响活动 runtime。
- 新增 `ExternalPluginRuntimeProcessHost`，拥有 session registry、driver factory 选择、Venera source-key 一致性、invoke/cancel/close 路由、并发 activation 串行化与 process restart 后不自动重放。
- driver 尚未真正关闭的 session 继续占用 process session limit；process close 与 payload 校验/driver 创建竞态时，activation 会失败并清理私有副本，不会发布立即失效的 session。
- Home startup trace、Reader demand/artifact ownership 与 dev.48 图片 codec 生命周期保持不变。
- Mihon `Source`/`SourceFactory` class-loader driver 和 Venera JavaScript engine 仍未实现。

## 0.31.0-dev.48：确定性动画 codec seam 与可排空图片测试生命周期

- 普通本地文件的 zero-copy 回归已改为纯 `localImageDirectFileProvider` 测试，不创建 Widget、不启动平台 `FileImage` 解码。
- 新增 `FlutterAnimatedCodec`、`FlutterAnimatedFrame` 与 `FlutterAnimatedCodecFactory`。生产默认 adapter 仍调用 `ui.instantiateImageCodec`；测试可以注入确定性 codec。
- 受控动画在 `endOfFrame` 后发布 `framePresented`/ready，并在替代帧可见前保留旧帧；generation 失效时释放 retained frame。
- 动画、文件和冷 artifact 测试使用 bounded wall-clock event-loop polling，并在 `finally` 中强制卸载异步媒体 Widget，避免失败用例把 codec/Timer/ImageStream 泄漏到 suite shutdown。
- Home startup trace 与 dev.47 外部插件 runtime worker、取消和 Android 平台通道保持不变。
- Mihon isolated class-loader driver 与 Venera JavaScript sandbox driver 仍未实现。

## 0.31.0-dev.47：隔离 runtime worker、协作取消与平台 backend channel

- 已实现生态无关的 `ExternalPluginRuntimeWorker`，作为 Mihon/Venera 隔离后端的服务端协议 owner。
- worker 在隔离边界内重解析请求，拒绝未知 source 与重复活动 request ID，并将后端异常净化为协议错误。
- raw channel 支持可选 cooperative cancellation；调用超时会发送 request-level cancel，但 host 并发许可继续由真实 backend Future 持有。
- worker close 可加入，先取消活动请求并关闭 driver，再等待真实调用完成。
- Mihon/Venera execution request 可序列化 exact immutable payload、批准能力和资源限制。
- Android host adapter 已实现 activation/invoke/cancel/close 的 MethodChannel 编排；native 侧在专用执行服务未安装时明确拒绝激活。
- 已增加两个生态共享的 worker conformance、取消/并发/关闭及平台 envelope 回归。
- Home startup trace、本地静态图片单 stream 和 promoted artifact active-run priming 保持不变。
- Mihon APK class-loader driver 与 Venera JavaScript sandbox driver 尚未实现。

## Current iteration — single image-stream ownership, active-run artifact priming and raw runtime channel

Report 30 showed two separate shutdown symptoms: animated first-frame regressions remained in loading, and the later plain-file provider test did not complete before the Flutter test platform was manually stopped. Static file presentation had two listeners on the same provider: the product manually resolved a `FileImage` for readiness while the `Image` widget resolved it again for rendering. The manual stream is removed. Static ready is now published only by the renderer-owned `frameBuilder`; the routing regression verifies `FileImage` and zero Dart byte loading without waiting on platform decoding, then unmounts it. Animated tests and the cold-artifact test yield the real event queue for host codec/file work and explicitly tear down players so codec timers cannot leak into later tests.

The promoted-artifact pool now treats `DownloadSession.beginRun` as the earliest authoritative cache-read signal. This starts the one exact persistent read while the replacement session restores its ephemeral workspace. Page media still only joins that read, and immediate snapshot delivery covers observers attached after the run began.

The external plugin runtime now has a raw message boundary in addition to protocol v1 and the source adapter. `ExternalPluginRuntimeHandshake` validates schema, runtime identity and unique source identities. `MessageChannelExternalPluginRuntimeConnection` serializes every request, parses every response, checks request identity and provides joinable close. Future Mihon process/Binder or method-channel implementations and Venera isolate/native-engine ports must implement this boundary; concrete APK class loading and JavaScript evaluation remain unimplemented. Home startup telemetry is unchanged.

## Current iteration — versioned external runtime protocol and shared source adaptation

The report-29 compile failure came from invoking `Duration.>` in a const initializer. `ExternalPluginRuntimeLimits` remains a const value object, while duration validation now runs at executor and session activation. Invalid limits still fail before any backend receives the inspected payload.

Mihon and Venera isolated backends now return an ecosystem-neutral `ExternalPluginRuntimeConnection`, not arbitrary zic sessions. A versioned request/response schema covers browse, comic detail, chapter manifest and binary resource operations. One host adapter validates source and content identities, constructs namespaced `BrowsableComicSource` values and enforces timeout, response size and concurrency independently of backend claims. Timed-out calls retain their permit until the real backend Future finishes; close signals the isolated connection, rejects queued work and drains actual operations. No Reader, navigation, demand, download-session or artifact authority crosses the protocol.

Home startup telemetry is retained unchanged. Concrete Mihon APK class loading and Venera JavaScript evaluation are still unimplemented isolated backends rather than implied by the shared protocol.

## Current iteration — visible-frame readiness, authoritative artifact reads and executable plugin requests

Home cold-start telemetry is retained unchanged because the reported delay is not currently reproducible. No new startup scan or eager diagnostic work is added.

The report-28 resource-cache failure is closed with `ResourceCacheFileByteStore`, an explicit composition of durable byte ownership and stable-file lookup. Local WebP `ready` now follows the renderer's first presented frame rather than container parsing. Promoted page bytes are primed only after the authoritative replacement session enters queued/receiving state; page media joins the same immutable read, and promotion waiting closes listener-attachment transition windows.

Mihon archive inspection now includes normalized entry classes without class loading. Separate `MihonIsolatedExecutor` and `VeneraSandboxExecutor` contracts pass the exact trusted payload plus bounded runtime limits to ecosystem-specific backends. These are execution boundaries, not engines: APK class loading and JavaScript evaluation remain unimplemented until isolated adapters satisfy the contracts.

## Current iteration — compact cover manifest, attributable Home startup and Android Mihon metadata

The dev.42 external compile report is closed in product types rather than tests. Memory encoded sources are no longer const-initialized from runtime bytes, optional durable-store capabilities are explicitly narrowed, nullable async index fallback is parenthesized, and byte-owned animation players cannot receive nullable data.

Warm durable cover lookup now loads one versioned compact manifest per process. Per-entry JSON remains an atomic recovery journal, target payload length is verified, touches are batched, and the normal path returns immutable files without materializing their bytes in Dart. Home emits one monotonic trace for bootstrap presentation, durable-service phases, cover request, source origin/length and first frame.

`plugin_host_bridge` implements the Android Mihon metadata boundary with background PackageManager archive parsing and no class loader. It returns package, current signer digest, version code and extension ABI to the existing trust gate. Venera inspection consumes one bounded immutable byte snapshot for both UTF-8 metadata discovery and SHA-256; JavaScript execution remains unimplemented and separately sandboxed.

## Current iteration — file-backed Home startup and immutable plugin inspection

The reported multi-second black interval is treated as a Home cold-start and local-file I/O problem, not a Reader playback problem. Flutter now mounts a startup surface before durable services open. Library read-state uses one bulk query; Home download badges use one index-only bulk projection. The persistent chapter service no longer restores every indexed page during `open` or creates sessions/stats page files for Home projection; exact commands materialize one session lazily. Warm durable covers resolve to validated immutable files and use an engine-facing file provider, while access recency is batched rather than flushed per hit. Plain local static images take the same path when no Reader/pipeline loader owns them. Network misses and Android content URIs still copy once into the durable response store, and animations/Reader pages retain their explicit owners. This removes avoidable whole-file Dart-heap copies but does not claim the platform decoder performs no internal copy.

The plugin runtime now includes concrete pre-execution inspectors. Both formats consume one immutable local payload, verify actual length and stream SHA-256. Mihon delegates package/signer/version/extensionLib extraction to a no-class-load Android metadata boundary. Venera performs bounded metadata-only source-key discovery and rejects repository/script disagreement without evaluating JavaScript. Trust/capability policy and separate executors remain authoritative.

The Flutter controlled-codec ready state now follows actual first-frame presentation, and the affected regressions retain strict product assertions while using valid packaged media and state-driven waits.

## Current iteration — direct promoted reads and gapless cold decode

A process-reopened Reader now shares one exact read of an already-promoted page artifact between the media consumer and the replacement session transport. Decode can start from the durable promoted bytes immediately; the new session still receives, seals and promotes in the background, and the shared read is released at the session terminal state. Cache handoff is bounded-chunk and cache read errors fail open to the normal source path.

Flutter animated target changes retain the last presented frame until the replacement codec presents a frame. Transition replay now reports artifact storage-read time, Reader join time and whether the measured event was `reader-direct` or `session-copy`, allowing cold-start traces to separate storage, decode and presentation costs. The reported static demo import failure is closed with an explicit downloads import, and the Reader midpoint regression keeps its no-dispose invariant during the transition window while permitting normal old-page eviction after settling.

## Current iteration — explicit artifact capability and evidence-driven Reader replay

The external dev.39 compile report exposed an invalid composition assumption: the App stored a persistent implementation
in a variable typed only as `ChapterDownloadService`, then passed it where `ArtifactCacheMaintenance` was required.
`ManagedChapterDownloadService` now expresses the actual aggregate capability (`ChapterDownloadService` + promoted
artifact store + busy-safe artifact maintenance). Memory and persistent owners implement it; narrower command-only adapters
remain legal. App root composition uses the aggregate type and no runtime cast or cache ownership is moved into Widgets.

The Reader midpoint test no longer assumes a fixed 300-pixel drag means the target page has been built. It advances the
gesture until target-host creation is observed while the source page remains current, then advances until the controller
reports the actual midpoint crossing. It still proves both loaded hosts have one creation and zero disposal events, so it
does not hide a product remount behind a weaker finder or end-state-only assertion.

`telemetry` now provides deterministic transition replay. Given a stable page asset key and the corresponding DownloadId
identity prefix, it correlates artifact source, decode/upload demand and start, decoded/uploaded/presented frame, first
Reader frame and page-host lifetime around one transition. Exact page/DownloadId identity construction now lives in
`downloads`, not App. The result separates transition revision from the revision that produced the presented frame,
reports preloaded neighbors as zero transition wait, exports JSON-ready measurements, missing events and host-remount
evidence. It is deliberately observational and cannot create demand, retain pages, or mutate cache policy.

## Current iteration — compile closure, attributable transitions and permissioned plugin runtime ownership

The dev.38 compile blockers reported by external Flutter/Dart validation are closed in product code. Persistent image
bytes are explicitly narrowed from the byte-store representation to the generic request type, maintenance calls use the
promoted maintenance capability, and `_ReaderPageHost` again accepts the stable key supplied by Reader composition.
No test expectation or finder was weakened to bypass these failures.

The real App cache composition is now a reusable `storage_bridge.createAppResourceCache` factory. An app-level restart
fixture opens that exact file-backed composition twice, restores both a source-card cover and a comic-detail cover, and
fails if the raw source is invoked after reopening. This complements package-level byte-store tests and prevents the
production root/path wiring from silently diverging.

Reader and session traces now attribute transition coverage, page-host lifetime, mount-to-first-frame delay, artifact
cache/origin selection, decode demand/start and upload demand/start to stable resource identity and demand revision.
Decode/upload revisions are retained with their demand while work waits in lanes or for source readiness, so a newer
pipeline plan does not relabel old queued work. This is observation only; no Presentation cache, keep-alive window or
parallel loading policy was introduced.

A new pure-Dart `plugin_host` package implements the common pre-execution boundary for Mihon and Venera compatibility.
Inspection is separate from execution. Policy can require HTTPS repository origin, payload digest, Mihon package,
signer, version floor and extension ABI, or restrict Venera capabilities and stable source-key discovery. Activation
failure quarantine prevents automatic retry loops. `ExternalPluginRuntimeRegistry` owns activated sessions, unload and
shutdown, and closes a new session before rejecting a source identity collision. Concrete APK/Kotlin and JavaScript
executors remain unimplemented and unclaimed.

## Current iteration — durable cover cache, stable Reader hosts and plugin catalog seam

Cover/image response caching now survives application restart. `ResourceCacheManager` accepts a dependency-light
`ResourceCacheByteStore`; App composition supplies `FileResourceCacheByteStore` under the durable storage root. Only
complete `imageBytes` values are persisted, with the full identity/namespace/revision key, expiry, content length and
content hash. The standard image TTL is seven days, source-composite invalidation also removes records not currently in
memory, and a changed source revision separates new cover content from an older URI/path identity.

The unified cache maintenance projection now reports process-memory responses, durable response bytes and page
artifacts as distinct tiers. Trim and clear wait for pending durable mutations, use the store's bounded LRU maintenance,
and continue to delegate page-artifact eviction through the existing busy-safe maintenance adapter.

Cache shutdown no longer increments the epoch before active loads finish. It rejects new public requests, drains the
already-owned futures and the serialized persistence queue, then closes the store. A cover that finishes while the app
is closing can therefore reach durable storage instead of being discarded by shutdown ordering.

Reader page presentation no longer keys `_ZoomableReaderPage` by current/non-current role. The zoom and media hosts use
the stable page asset key; crossing the PageView midpoint updates `active` and resets page-local zoom in place without
recreating the media child. This removes the observed second loading/black frame caused by role-key remounts without
adding Presentation keep-alive or prefetch policy.

`catalog` also defines a format-neutral external plugin catalog seam. Mihon extension indexes preserve package/source
identities. Venera indexes accept both `filename` and the current repository's `fileName`, preserve a declared `key` as
`venera:<key>`, and defer runtime source discovery only for keyless entries. Executable APK/Kotlin and JavaScript
integration must remain separate `ExternalComicPluginHost` implementations and return explicitly closable sessions of
ordinary `BrowsableComicSource` adapters. This iteration parses and validates repository metadata; it does not claim
executable plugin support.

## Current iteration — promoted Reader artifact cache handoff

Reader sessions still use an isolated `EphemeralCacheWorkspace`, but promoted pages no longer disappear with it. The
`downloads` package now owns `ArtifactCacheStore`, a read-through `ArtifactCacheTransport`, and
`PromotedArtifactCacheHandoff`. The handoff observes authoritative `DownloadSession` snapshots, commits only final
promoted bytes, and drains before Reader workspace deletion. It does not create demand, choose a prefetch window or
retain decoded/presented resources.

`PersistentChapterDownloadService` stores the committed page through its existing registry, `DownloadJob`, artifact,
SQLite index and `CacheOps` path; the memory fallback provides the same exact-page contract. A later Reader session can
serve those bytes through the cache transport and then reconstruct its own session artifact without repeating source
network transport. Ambiguous URI mappings are not cached, and range reuse uses a content-derived validator.

`resource_cache` remains dependency-light and does not import `DownloadId`. Failed source-response coalescing no longer
creates an unobserved derived Future, so retryable browse/detail failures remain owned by the screen's existing error
state. Download Manager also renders its empty task state alongside cache usage instead of showing only maintenance
statistics.

## Current iteration — unified resource cache and restored pipeline ownership

The first Home decomposition remains: `DemoHome` coordinates routes and cross-feature use cases, while
`demo_home_views.dart`, `home_widgets.dart` and `HomeLibrarySession` separate presentation composition and durable
projection. The resource-policy part of `0.30.0-dev.35` is superseded. App-owned cover/page caches and direct Reader
adjacent-page warmup have been removed.

`resource_cache` is now a workspace package shared through composition. One `ResourceCacheManager` owns cover/image
responses, comic details, chapter metadata and search results with a global budget, per-kind budgets, TTL, in-flight
request coalescing, LRU eviction and exact source-composite namespaces. Invalidation also supersedes older in-flight
responses, so refresh or clear cannot be repopulated by a late stale request. Download Manager reports each response
kind together with the persistent artifact tier.

`CachedBrowsableComicSource` is the catalog adapter. Browse/detail/chapter metadata and source artwork use the shared
manager. Raw chapter-page `loadResource` calls deliberately bypass it and continue through
`ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession/artifact`. The competing
`ReaderPageBytesCache`, current/adjacent warmup and implicit retention were removed; page-role changes again reset
per-page zoom rather than preserving stale transforms.

`ChapterDownloadService`, persistent page-artifact maintenance and `WholeComicDownloadQueue` now live in the pure
`downloads` application-service package. `downloads_bridge` owns only runtime network/power and JSON persistence
adapters. A partially downloaded chapter is represented by its independent page artifact records while chapter
metadata remains a separate cached response; no chapter-sized all-or-nothing cache object is introduced. The in-memory
fallback now retains and evicts individual pages too, so cancellation and retry exercise the same partial-chapter
contract as production. Cache identities for local/remote cover resources are created by catalog adapters, not App UI.

## Current iteration — source migration candidate comparison

Cross-source migration now stops at a read-only evidence boundary before any target comic, preference, chapter,
progress or read-state write. `ComicSourceMigrationComparison` is derived from the existing conservative plan and
reports both source-composite identities, normalized title and author evidence, reading-direction differences,
exact versus sequence-only matches, unmatched source/target counts and bounded chapter-pair samples.

The App presents current and target works side by side with cover, authors, source name, native ID, chapter count
and reading direction. Explicit risk rows explain title/author/direction differences, sequence-only candidates and
unmatched saved chapters. The final copy action remains disabled until the user acknowledges the target identity
and risks. Comparison cover futures are cached for the dialog lifetime; rebuilding the acknowledgement state does
not re-fetch remote covers. The existing pre-write target manifest validation and exact-only reading-state transfer
remain unchanged.

## Current iteration — download manager OOM and queue shutdown repair

Download Manager's per-chapter task expansion now advances its explicit index. A non-empty task list can no longer enter an infinite synchronous Widget-construction loop and exhaust the host process or WSL memory. The Dart structure gate also rejects conditional C-style `for` loops whose update clause is empty, so this failure class is detected without launching Flutter.

`WholeComicDownloadQueue.close()` now marks running jobs resumable, cancels and drains active chapter work, publishes the resulting durable state, then detaches runtime-environment signals and closes the store and change stream. The supplied chapter-download, library and source-browser test files use bounded frame advancement and explicit Widget-tree teardown; product interaction semantics are unchanged.

## Previous iteration — durable whole-comic queue and runtime policy signals

The whole-comic operation is now a durable scheduler rather than a route-local loop. `WholeComicDownloadQueue`
persists exact source-composite comic ownership, the chapter catalog, completed chapter identities, policy,
phase and failure state to JSON. A restored `running` job becomes `queued`; every chapter is re-inspected against
the authoritative `ChapterDownloadService` before work starts, so promoted artifacts remain the source of truth.

The scheduler enforces a global chapter concurrency limit and exposes pause, resume, cancel, retry and record
removal. An active duplicate enqueue is coalesced instead of replacing the live job. Network/power policy can
require unmetered connectivity or charging. If a condition becomes false during an active chapter, the queue
moves the job to `waitingForPolicy`, cancels that chapter through the existing service, and resumes later through
the same partial-artifact/session boundary.

`runtime_bridge` is a narrow Android signal plugin, not a downloader. Its versioned method/event channels expose
validated network availability, Android metered state and charging state. Download Manager renders durable queue
jobs and edits policy while continuing to show per-chapter tasks separately. Unsupported hosts use the explicit
injectable environment fallback.

The missing `_librarySortLabel` implementation that blocked the App test kernel is restored as an exhaustive
mapping. Reader playback speed now uses a centered bounded dialog, keeping all five choices reachable on small
viewports. Queue concurrency, policy waiting/loss, persistence and manager controls have dedicated regressions.

## Previous iteration — cover-owned management and authoritative whole-comic downloads

Bookshelf management again keeps single-comic actions on the cover: delete is isolated at the upper-right
and category migration remains a lower-right popup. A long press is the only entry into source-composite
multi-selection; the batch surface owns only batch move, copy, clear and confirmed delete. Custom-order
dragging uses a dedicated handle so it does not steal the multi-select gesture.

Local and remote details subscribe to the authoritative chapter-download stream and inspect durable state
on entry. Chapter rows therefore retain active/complete state across route recreation. A single chapter
uses its own title and page denominator on the cover, while an explicit whole-comic operation aggregates
all known chapters and downloads incomplete entries sequentially through `ChapterDownloadService`.
Cancellation stops the sequence; completion returns the cover to normal brightness and leaves only a compact
offline marker. Download Manager omits progress bars for complete tasks and uses the chapter name as the
primary label.

Home, History and Bookshelf keep the same cover geometry with no metadata rows below it. The comic title is
overlaid at the lower-left; reading progress is shown only in details. Exact source-composite route locks
coalesce rapid taps from local and source cards. Reader speed choices use a bounded overlaid popup and chapter
rows own a Material surface, repairing the reported small-screen and ink assertions without bypassing the
underlying interactions.

## Current iteration — migration diagnostics and interaction reliability

SQLite schema version 6 retains the source-composite library tables and adds `acknowledged_us` to
`library_migration_issue`. The Store can list only pending diagnostics or all retained diagnostics and
can acknowledge issue IDs transactionally. Acknowledgement is presentation state: it never deletes,
reassigns or rewrites the ambiguous legacy record.

`LibraryDiagnosticsScreen` exposes the migration evidence through selectable detail JSON, full JSON
clipboard export, refresh, pending/all filtering and individual or bulk acknowledgement. It is reachable
from the existing diagnostics area without adding another persistent catalog or migration owner.

Reader controls remain at their final overlay positions while opacity changes, so the control is
hit-testable as soon as the visible state changes. Local and remote details keep separate state owners,
but chapter opening and downloading now have independent work locks and share one in-flight manifest
ensure operation. The read-state row uses a non-destructive right-swipe action instead of a dismiss
lifecycle. Bookshelf sort and move actions use explicit bottom sheets with stable identities.

## Previous iteration — source-composite durable library identity

SQLite schema version 5 now keys imported chapters, reading progress, comic preferences and chapter
read state by `sourceId + nativeId`. `ReadingProgress`, `ComicPreference` and `ChapterReadState` carry
and serialize the source identity; Store point queries/removals and App maps use the same composite
identity. Different sources can therefore retain identical native comic/chapter IDs with independent
progress, preference, read state and deletion lifecycles.

Schemas 1–4 migrate transactionally. Legacy chapter-owned progress/read state inherits its imported
chapter source. A remote preference with multiple possible owners is assigned by deterministic
saved/import recency and every ambiguity/orphan is persisted to `library_migration_issue` rather than
silently overwritten or discarded. A foreign-key check must pass before the migrated schema version
is committed. Legacy JSON remains readable through explicit owning-source fallbacks; all new writes
include the source.

Cross-source copy no longer rejects an otherwise valid target only because another source uses the
same native ID. Every exact target chapter is freshly resolved and identity-validated before the first
durable write; target preferences are merged and existing target progress/read state is preserved.
Home/history/source cards and details chapter/read/download Widget keys are also source-composite,
preventing Flutter element state from leaking between sources.

The reported `void` callback branch returns and `SavedComicRecord.fromJson` list promotion failures are
fixed. Schema isolation, schema 4→5 ambiguity reporting and legacy JSON compatibility have dedicated
regressions.

## Previous iteration — two detail owners, whole-comic persistence and chapter downloads

`RemoteComicDetailsScreen` and `LocalComicDetailsScreen` own different lifecycles while composing the
same header, preference/category controls, chapter rows, error presentation and pull-to-refresh
scaffold. The former `resolveComicDetailsRoute` compatibility facade has been removed: current App
composition resolves same-source canonical aliases and routes to the strongest durable raw locator.

`SavedComicRecord` separates whole-comic persistence from chapter persistence. SQLite schema version 4
stores source-aware comic metadata and a lightweight chapter-catalog snapshot. Liking, collecting or
adding a comic to the shelf can therefore retain the whole work with zero imported chapters. Chapter
click opens Reader; the chapter trailing action downloads that chapter.

`PersistentChapterDownloadService` uses the existing DownloadRegistry/DownloadJob pipeline but places
complete promoted page artifacts under a persistent offline root. It verifies complete chapters and
reopens page bytes after service restart. Reader selects those loaders only when the whole chapter is
complete; temporary Reader workspaces remain separately owned.

Cross-source migration is explicit and copy-based. It searches the selected target source by the
current title, lets the user confirm a candidate (or provide a manual native ID), copies whole-comic
preferences, fetches target chapter manifests, and migrates progress/read state only for
normalized-title plus sequence matches.
It never copies source URLs or offline bytes and never deletes the original source. At that release,
legacy preference/chapter/read tables were still keyed by native IDs, so collision guards stopped or
skipped unsafe writes; schema version 5 supersedes those guards with durable composite identity.

The reported missing `ImportedChapterRecord` type import is fixed in `library_comic.dart`. Reader zoom
uses an app-owned two-tap window whose timer is canceled on disposal, and App tests wait for explicit
state/hit-test conditions instead of indefinite settling around continuously animated media.

## Previous iteration — unified source-aware details and pull refresh

Comic Sources, Home updates, reading history and Bookshelf now route through one
`UnifiedComicDetailsScreen`. The screen renders the same cover, metadata, preferences, categories,
source filters, order control, read dimming, restore-unread gesture and chapter actions regardless of
entry point. The former remote-only details widget is now only a thin adapter into this common state
model.

The projection deliberately separates two layers. A source manifest is the complete current upstream
chapter catalog; `ImportedLibraryEntry` is the subset the user has opened or explicitly saved. They
merge by `sourceId + chapterId`, so refresh can reveal new chapters without silently adding them to the
library, while persisted chapters missing from a successful upstream response remain visible as local
retained entries. Source filters keep identities separate when an aggregate exposes more than one
source. Read and in-flight state also use the composite source/chapter identity inside the details UI.

Pull-to-refresh and the app-bar refresh command call each owner rather than bypassing it: remote
catalogs refresh through `BrowsableComicSource.loadComic`, local folders through the injected folder
refresher, and persisted state through `ImportedLibraryStore`. Reader/DownloadSession ownership is
unchanged. Remote author/description/cover metadata is persisted on chapter records with legacy JSON
fallbacks so Home/history can render the same details before the next network response.

The App now imports the domain models used by its source-to-library adapter, repairing the reported
`Comic`/`Chapter` compile failure. The Reader double-tap test retains two real taps and the zoom
assertion, then advances beyond the recognizer countdown so no timer remains after disposal.
Repository structural checks pass here; Flutter/Dart/Cargo/Android toolchains remain external gates.

## Previous iteration — remote comic source browser

The Android shell now has a lazy-created third `漫画源` destination, so startup does not browse the network. The top app-bar action opens a reorderable
source manager; the source page keeps a compact bottom switcher for enabled sources. Search, refresh,
paging, retry, comic details and chapter add/open actions are implemented without creating a second
Reader or library model.

`catalog` now owns `BrowsableComicSource`, descriptors and browse summaries. The first built-in
implementation is `MangaDexSource`, using injected `Transport` for API/cover requests and resolving
chapter pages through MangaDex@Home. The production default requests English safe/suggestive
content. Fixture transport tests cover browse, metadata, chapters, covers and imported records; App
widget tests use injected sources to cover the third destination, switching, management and the
remote-to-library path without external network access.

The browser is network-lazy: fixture regressions assert that no source browse occurs before the
third destination is opened. Metadata and cover/resource responses are bounded before buffering,
and a transient detail error exposes an in-place retry instead of requiring route recreation.

Remote chapters are converted to `ImportedChapterRecord` and then use the existing durable library
and Reader DownloadSession/promoted-artifact ingress. `ImportedPageRecord` now persists optional
source page IDs. Progress reconciliation uses that ID across rotating delivery URLs and retains a
legacy display-name fallback. SQLite schema version 3 persists `ComicSourcePreference`; version 2
migrates by adding only the new source preference table.

Mihon/Venera executable loading is not embedded in the built-in source iteration. `0.31.0-dev.38`
adds strict repository metadata parsers and an isolated host/session ABI, but Android APK/Kotlin and
JavaScript runtimes still require separate compatibility, trust, permission and sandbox implementations.
No login, Cookie, challenge-solving or anti-bot bypass was added.

`python3 tool/check_repo.py` and static repository checks pass in this environment. Flutter, Dart,
Cargo, Android SDK and Android NDK are unavailable, so analyzer, Flutter tests, Rust tests and APK
builds remain explicit external gates.

## Previous iteration — library management and immersive Reader controls

The Home product surface no longer exposes per-directory refresh/removal maintenance. Folder
import remains a first-class action, while media diagnostics are collapsed under a secondary
expansion section. Home update/history rails and the Bookshelf gallery now instantiate the same
`ComicCoverCard` with an exact 132 × 238 card extent and 3:4 cover ratio. The gallery centers
fixed-width cards instead of stretching them to fill arbitrary grid cells.

Bookshelf sorting no longer changes presentation mode. Gallery and list are explicit user-selected
views; custom order works in either. In management mode, a card tap selects the comic and exposes
move/category/copy operations. Deletion is separated by spacing and a divider, uses the error color,
and requires confirmation. Custom gallery order uses long-press drag targets; custom list order uses
`ReorderableListView`. A selected category can add one or more existing shelf comics, and move
semantics remove the active category before adding the target category. Duplicate inner shelf titles
and selected-chip checkmarks were removed.

Reader enters `SystemUiMode.immersiveSticky` with both control surfaces hidden. A page tap toggles
top and bottom overlays. The bottom overlay owns the page slider, pause, playback speed, clockwise
rotation, favorite and chapter-cache commands. Page jumps remain `ReaderController` commands.
Pinch/pan and double-tap zoom are page-local; PageView scrolling is disabled while zoomed and the
old page is rebuilt at identity scale after navigation.

Animation control is injected into the existing `NativeWebpPlayer`/Flutter codec composition rather
than replacing it. Controlled WebP decoding retains viewport-aware target dimensions, telemetry,
download identity and the native fallback boundary. Native and Flutter timers preserve remaining
frame delay across pause and speed changes. The chapter-cache action promotes all chapter pages in
the current Reader workspace; that workspace is intentionally session-scoped, so a durable offline
projection and persistent shelf waterline remain the next storage slice.

`python3 tool/check_repo.py` passes in this environment. Flutter, Dart, Cargo, Android SDK and
Android NDK are unavailable here, so the target tests, analyzer and device/native builds remain
external validation gates rather than claimed results.

## Previous iteration — comic-level aggregation and reliable unread restore

The persisted library now exposes a catalog-owned `LibraryComic` projection that groups
all `ImportedLibraryEntry` snapshots with the same `sourceId` and `comicId`. `ImportedChapterRecord`
persists a backward-compatible `comicTitle` and chapter `sequence`, allowing local and
future remote chapters to share one cover, preference record, shelf position and details
route without moving chapter progress or refresh ownership out of the store.

Home update/history rails and Bookshelf filtering, sorting, custom ordering, category
membership and comic deletion now operate on comic aggregates. The details route renders
all grouped chapters in sequence order, opens the selected chapter, and keeps precise
progress plus explicit read state per chapter. Refresh and identity-reconciliation ownership remain
chapter-scoped in the source/store layer; the later library-management iteration removes those
maintenance controls from the Home product surface.
Refresh copies the scanned source revision and page snapshot onto the existing chapter,
preserving its aggregate `comicId`, `comicTitle`, chapter identity and sequence.

The reported restore-unread failure was a product gesture-boundary problem: the stable key
was attached below the `Dismissible`, and the default 40% threshold made the exact test and
real short swipes unreliable. The key now identifies the gesture owner, read chapters alone
accept start-to-end dismissal, and a non-destructive 18% threshold invokes the persisted
unread transition while returning `false` to retain the row.

Two test files also contained registrations outside `main()`. Those compile breaks were
repaired without changing their assertions. A nullable constructor-parameter reference found
during delivery review was corrected to validate the normalized field. Repository structure,
native-header, JSON, shell syntax, delimiter, test-registration-scope and version-consistency
checks pass in this environment. Flutter, Dart and Rust toolchains are not installed here;
the source libwebp check also cannot fetch its pinned checkout because outbound DNS is blocked.
The full commands in `NEXT_CHAT_HANDOFF.md` remain an external validation gate.

## Previous iteration — persisted directory refresh and stable page reconciliation

Persisted local chapters can now be rescanned without reopening the system picker. Android
reuses the stored SAF tree URI through `scanImageDirectory`; desktop platforms rescan the
stored filesystem directory outside the UI isolate. The bridge protocol is version 3 so a
Dart refresh request cannot silently target older native code that only supports initial
selection.

Imported page IDs are derived from stable source identities rather than list positions.
When refresh inserts or removes files before the current page, both memory and SQLite
stores reconcile `ReadingProgress` to the same source when it still exists; only a removed
current source falls back to a clamped valid page. The source/store path supports per-chapter
refresh progress and reports added/removed page counts while leaving the previous chapter
untouched when scanning fails. The later library-management iteration removes that maintenance
presentation from Home while retaining the underlying refresh contract.

The directory test fixture now uses a complete decodable PNG. A 24-byte signature/IHDR
prefix is correctly rejected by the production sniffer because it cannot satisfy the
minimum 33-byte PNG header contract.

## Previous candidate — durable imported library and progress restore

Imported image folders now become durable catalog entries rather than route-local values.
`catalog` owns the `ImportedLibraryStore` contract and in-memory reference implementation;
`storage` provides a transactional SQLite implementation, while `storage_bridge` resolves
the Flutter application-support path. The App lists stored chapters, removes entries,
reopens content-URI or filesystem pages through the same LoaderTransport/DownloadSession
artifact ingress, and restores the last page plus paged/continuous mode.

Progress writes are monotonic by `updatedAt`, chapter refresh clamps an out-of-range page,
and SQLite delete uses foreign-key cascade. Reader viewport reconstruction preserves the
current page and direction while detaching the previous demand plan before disposal.

PNG directory sniffing now rejects a bare signature or incomplete IHDR label. Both Dart and
Android require a complete signature, IHDR length/type and non-zero dimensions before
returning PNG; full codec validation remains authoritative after admission.

## Previous candidate — imported-folder Reader artifact pipeline

The working folder importer now crosses the same production Reader boundary as manifest
chapters. A selected folder is normalized into a serializable `ImportedChapterRecord` with
stable source/comic/chapter/page identities and a revision derived from the ordered page
sources and media hints. Content URIs and filesystem paths retain distinct canonical URI
semantics, including Windows drive paths.

`ImageFolderScreen` no longer owns a standalone page index or reads the selected file
directly. It builds a `ChapterManifest`, registers platform byte loaders with
`LoaderTransport`, and runs through `ReaderRuntimeScreen`, `LiveCoordinator`,
`DownloadSession`, promoted artifacts, `ReaderBinding`, and `ReaderView`. Previous/next and
menu navigation are explicit `ReaderController.requestPage` commands consumed by
`ReaderView`; page disposal cancels pending artifact waits immediately.

Temporary cache paths, artifact reads and recursive cleanup are owned by
`packages/storage/EphemeralCacheWorkspace`; the App composition layer no longer imports
`dart:io`.

Directory-provided byte lengths are propagated into page/catalog metadata. `LoaderTransport`
includes a full-byte content hash in resume validators, so replacement content with the same
URI and length cannot be appended to a stale partial artifact.


The WebP directory sniffer now rejects incomplete `RIFF`/`WEBP` labels and a missing first
chunk tag while remaining permissive about unknown printable chunk types. Full validity is
still owned by the parser/codec. The version remains `0.18.3-dev.21` pending the external
Flutter/Android gate.

## Previous candidate — local-media package boundary and deferred SAF validation

Local image models, recursive filesystem enumeration and header sniffing have moved from
`apps/app/lib` to `packages/local_media`. The App retains only a compatibility export and
UI behavior. Android document-tree access remains in `packages/local_media_bridge`.

The Android scanner now retains MIME/name image candidates when a header stream cannot be
probed, and document reads try ordinary, asset-file and typed-asset resolver streams. A
protocol-version handshake detects stale cached native plugin code and instructs a clean
build instead of reporting its old empty-directory result as current behavior.

`tool/clean.sh` removes project Flutter/Dart, Gradle, Rust, CMake/libwebp and generated JNI
build caches while preserving lock files and pinned source.

# Implementation Status

## Previous candidate — Android scoped document-tree folder import

The remaining Android folder-import failure was not a filename or WebP signature problem.
The endorsed selector returned a raw filesystem path for a selected SAF document tree,
while single-file selection read through `ContentResolver`. On scoped-storage devices the
raw path does not inherit the tree URI grant, so directory probing could not reliably read
the same bytes that the single-file WebP workflow could open.

A dedicated `local_media_bridge` plugin now owns Android `ACTION_OPEN_DOCUMENT_TREE`,
persists the read grant, recursively enumerates `DocumentsContract` children, probes each
document through `ContentResolver.openInputStream`, and returns immutable content-URI
identities with explicit relative display names and detected formats. Switching pages reads
the selected document through that same content URI instead of reconstructing a raw path.
Recognition is layered: magic bytes are authoritative for admission, provider MIME is a
compatibility fallback, and the display-name extension is used only as the final candidate
hint; the real parser/codec still validates bytes on open. Scan results expose separate
header-recognized and metadata-fallback counts for device diagnostics. Desktop and other
IO platforms retain the isolate-backed filesystem scanner.

`PickedImage` now has an explicit `sourceId` and byte-loader contract in addition to its
compatibility `XFile`. This keeps content URI identity, display name and bytes coupled
without relying on `XFile.name` or treating a content URI as a filesystem path. Signature
checks are intentionally minimal magic-byte sniffing; the full WebP parser or Flutter codec
remains authoritative after selection. Empty-folder diagnostics now use stable wording for
scanned, unrecognized and unreadable file counts.

The package version remains `0.18.3-dev.21` until Flutter and Android device validation
passes. This candidate is not a stable baseline.

## Previous candidate — native contain geometry and permissive image sniffing

The Android external texture was previously inserted directly into a tight expanded
viewport. `Texture` has no `BoxFit`, so it stretched to the viewport even though the
reported display/decode dimensions retained the expected source ratio. Native output now
uses `NativeTextureViewport`: a centered source-canvas `AspectRatio` box provides contain
geometry and the texture fills only that box. Wide and tall layout tests cover the visual
contract independently of Android texture registration.

Folder import now treats signature recognition as format sniffing rather than full
container validation. WebP files with metadata or unknown RIFF chunks before the image
chunk are accepted by the folder boundary as long as RIFF/WEBP and a readable first chunk
tag are present; the actual WebP parser/codec remains authoritative. File-length values
smaller than an already-read prefix no longer invalidate the prefix. BMP and other raster
magic checks use minimum structural fields rather than requiring an entire declared file
inside the 64-byte probe. Empty-folder diagnostics report scanned, unrecognized and
unreadable counts separately.

Generic-image readiness is now driven by a shared `MemoryImage` stream listener instead
of a render-time `frameBuilder` callback. Production uses the same provider for readiness
and display, avoiding a second decode; tests may inject an explicit decode probe to cover
ready/failure transitions without waiting on the Flutter test image pipeline.

The package version remains `0.18.3-dev.21` until the external Flutter/Android validation
gate passes. This candidate is not a stable baseline.

## Previous candidate — header-detected mixed-image folder import

Directory import no longer filters filenames for `.webp`. It recursively examines all
ordinary files outside the UI isolate, probes their file headers, and creates a
`PickedImageFolder` containing explicit relative names and detected formats. Files with
missing, misleading or uppercase extensions behave identically. A folder is considered
empty only when no recognized image signature is present; diagnostics retain scanned
and unreadable counts. Android `content://` results are rejected as an unsupported path
contract rather than being misreported as an empty folder.

The two preview-state timeouts reported in `app_smoke_test.dart` are removed from the
smoke boundary. Reader hosting and folder switching now assert keyed component identity,
source URI, format and explicit loading state while byte futures are deliberately held.
Valid/invalid decoder completion remains in dedicated preview tests. Both WebP and mixed
image players publish their current state snapshot after first layout so an observer
cannot miss the initial state.

The package version remains `0.18.3-dev.21` until the Flutter/Android validation gate
passes. This candidate is not a stable baseline.

## Previous fixed-overlay baseline — production Reader artifact ingress

### Baseline ownership

The current baseline is the prior complete WebP-safe-folder candidate with the five
files from `fixed.zip` replaced exactly as recorded in
`docs/FIXED_OVERLAY_BASELINE.md`. All work below is layered on that merged tree.
The package version remains `0.18.3-dev.21` until Flutter and Android validation
passes; archive names no longer carry the old
`_webp-safe-folder-candidate_UNVERIFIED` suffix.

### Reader production ingress

The Reader app runtime no longer composes its demand plan with `FakeCoordinator`.
`ReaderBinding` now drives a real `LiveCoordinator` and `DownloadRegistry`. Asset,
file and HTTP identities use the manifest-owned `DownloadId`; media bytes are read
only after the corresponding `DownloadSession` reaches `promoted`, so Reader
telemetry and the displayed WebP share the same source identity and artifact.

`DownloadSession` exposes an observer-safe snapshot contract for promotion/failure
waiting. Observer failures cannot mutate or abort the authoritative state machine.
The app runtime detaches every prior demand plan when the physical viewport target
changes and again on disposal, then cancels coordinator work before disposing the
registry and its temporary artifact root. `NativeWebpPlayer` also owns a
`WebpLoadToken`; disposal cancels an in-flight promoted-artifact wait and immediately
removes its snapshot listener. This closes stale-demand, offscreen-listener and
teardown races that were hidden by the previous fake coordinator.

This is a staged production integration: network/artifact ingress is real, while the
visible Reader WebP remains on the crash-safe Flutter codec. Native decode/upload/
present remains an explicit standalone experiment until device lifecycle checks pass.

### Test synchronization

The overlay's local Flutter fixes are preserved, but asynchronous preview tests now
synchronize through explicit preview-state regions, observer snapshots and controlled
picker/catalog futures. They do not advance a guessed fixed frame duration, identify components by
copy, or depend on `XFile.fromData` metadata.

### Validation status

Repository constraints and available host syntax/native-stub checks pass in this
sandbox. Flutter, Dart, Rust/Cargo, Android SDK and Android NDK remain unavailable,
so this tree is still an unverified candidate and is not a stable versioned baseline.

## Unreleased candidate from 0.18.3-dev.21 — crash-safe WebP entry and local folder switching

### Reader smoke timeout repair

The failing helper repeatedly issued zero-elapsed pumps while waiting for a widget
inside a route transition. Elapsed transition time never advanced, so the keyed
Reader media page remained offstage even though the destination route had been
pushed. Navigation coverage now stops at the keyed destination route with
`skipOffstage: false`. Reader media content is a separate test that injects a
one-page chapter manifest directly and synchronizes on `WebpPreviewState.ready`.
Catalog and static routes likewise use stable screen/entry keys rather than copy.

### Crash-safe WebP activation

Reader media, bundled WebP, local single-file import, and local-folder import all
start on `WebpPlayerEngine.flutter`. Reader and folder switching keep engine controls
hidden so their normal workflows cannot start FFI/texture. In standalone previews,
selecting `Native（实验）` opens an explicit confirmation dialog; cancellation leaves the
Flutter engine selected without native work. Native initialization and present
failures still emit attributed fallback telemetry and return to Flutter codec.

Android `SurfaceProducer.scheduleFrame()` is posted to the main handler rather
than called from the serial blit worker. Surface callbacks use
`onSurfaceAvailable`/`onSurfaceCleanup`; the blit lane retains the current frame
for redraw and releases it on replacement, resize, output release, or detach.

### Original local WebP folder stage (superseded)

This stage first introduced recursive folder enumeration, natural sorting, explicit
relative display names and a single current player. The current candidate supersedes
the `.webp` filename filter with mixed-image file-header detection while retaining
those ownership and switching guarantees.

### Validation status

Repository constraints and available syntax/native stub checks pass in this
sandbox. Flutter, Dart, Rust/Cargo, Android SDK, and Android NDK are not installed
here, so the target Flutter tests and device/native gates must still be run in the
external toolchain environment. Version remains `0.18.3-dev.21`; this is an
unverified validation candidate, not a stable baseline.

## 0.18.3-dev.21 — unambiguous malformed-WebP error state

### Root cause

The malformed-file preview rendered two widgets containing `WebP 文件无效`: the primary validation detail and the footer status. `find.textContaining` therefore correctly returned two matches even though navigation, filename ownership, and validation were all working.

### Repair

The detailed validation message now owns `webpPreviewErrorKey`. The footer reports the broader state `加载失败`, while the test waits for and reads the keyed detail widget. Repository gates reject both a duplicated footer validation phrase and a return to page-wide text matching.

### Validation before the next chat

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.3-dev.21.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.2-dev.20 — explicit local-import display-name ownership

### Root cause

`XFile.fromData(..., name: ...)` does not provide a portable guarantee that the resulting `XFile.name` is non-empty in every Flutter test backend. The previous route synchronization repair reached the correct preview screen, but `WebpPlayerScreen.file` reconstructed its title from `file.name`, so the keyed title existed with an empty string.

### Repair

`WebpPicker` now returns `PickedWebp`, which owns both the `XFile` and its normalized `displayName`. Production system-picking derives the name from `XFile.name`, then the path basename, then `本地 WebP`. Tests inject the expected display names explicitly. `DemoHome` passes the owned name into `WebpPlayerScreen.file`, and the screen only falls back to file metadata when no explicit non-empty name is supplied.

The stable route/title keys and bounded pumping remain in place. This separates three concerns cleanly: asynchronous route synchronization, selected-file bytes, and user-facing naming.

### Validation before the next chat

Run at minimum:

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.2-dev.20.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.1-dev.19 — deterministic local-import route tests

### Picker route synchronization

The local picker is asynchronous and the material route transition is scheduled after the picker future completes. A single fixed-duration `pump` can end on the first route frame rather than after the destination is discoverable, so exact-title finders were timing-dependent. The preview now exposes stable screen and title keys, and the widget tests use a bounded frame pump until the destination marker appears.

Malformed imports use the same route marker, then independently wait for the controlled `WebP 文件无效` state. This preserves the product behavior while removing dependence on animation timing and codec scheduling.

### Next chat

Continue from `zic_v0.18.1-dev.19.zip` only. The next engineering target remains Android `SurfaceProducer` texture presentation, followed by runtime telemetry and real reader-page integration.

## 0.18.0-dev.18 — validated local import and source-aware raster quality

### Local import stability

The picker route test now injects the real finite-loop WebP asset rather than a twelve-byte RIFF signature. `WebpInfo` validates complete RIFF length and reads VP8X, VP8, or VP8L canvas dimensions before the preview creates a Flutter or native codec. Malformed imports remain on the preview route and show a controlled error instead of feeding invalid bytes into the image pipeline.

### Decode raster versus display target

`DecodeTarget` remains the DPR-aware, eight-pixel-aligned physical display target. The new `RasterPlan` derives the actual encoded-image decode dimensions. Large images are downsampled to the bounded display target, while sources smaller than the viewport remain at intrinsic dimensions. This prevents animated codecs from interpolating tiny partial subframes before composition and avoids allocating multi-megapixel buffers for four-pixel fixtures.

Both native `RawImage` and Flutter `Image.memory` use nearest-neighbour rendering only for very small sources enlarged by at least 2x. Normal comic pages retain medium filtering. Native cursor identity follows the decode raster, so viewport-only display changes no longer recreate a cursor when the decoded pixel dimensions remain unchanged.

### Next iteration

1. Move native RGBA presentation to Android `SurfaceProducer` texture output.
2. Add device telemetry for decode raster, display scale, frame preparation, and present deadlines.
3. Connect the source-aware raster plan to real reader page decode sessions.
4. Add local chapter/CBZ import with persisted catalog metadata.

## 0.17.0-dev.17 — adaptive physical targets and deadline-based WebP playback

### Compile and target repair

`static_demo.dart` now imports the pipeline contract that owns `DecodeTarget`. The target itself has moved into a dedicated pure-Dart module. `DecodeTarget.viewport` converts logical viewport dimensions through the device pixel ratio, while `DecodeTarget.fit` preserves a known source aspect ratio inside that physical viewport. Both paths align dimensions to eight pixels and enforce a bounded decoded-pixel budget.

The static reader recreates its diagnostic binding when MediaQuery dimensions or DPR change. The Animated WebP preview derives its target from the exact `LayoutBuilder` image area, so app bars, controls, rotation, split-screen, and device density are reflected in decode identity.

### Flutter codec scaling

The Flutter path no longer places an intrinsic-size `Image.memory` inside a loose `Center`. It receives tight full-area constraints and matching physical `cacheWidth`/`cacheHeight`, with medium filtering. Tiny bundled fixtures now fill the preview correctly, while large imported files are decoded to the same bounded physical target as native.

### Native pacing

The previous preview decoded the next frame only after the current frame timer expired, making wall time equal to encoded duration plus decode/image-construction time. The player now decodes and builds the next `ui.Image` while the current frame is visible. `FramePacing.remaining` subtracts that preparation time from the current frame duration and presents immediately on overrun. Pause/resume preserves pending deadlines, and finite playback waits through the final frame duration before reporting completion.

### Next iteration

1. Replace diagnostic RGBA-to-`ui.Image` copies with Android texture upload.
2. Feed viewport target revisions into real reader decode sessions without recreating diagnostic controllers.
3. Add device timing telemetry comparing encoded, decode, upload, and present intervals.
4. Add local chapter/CBZ import and persistent catalog entries.

## 0.16.0-dev.16 — runnable Animated WebP app entry and local import

### Bundled animation assets

The three deterministic native decoder fixtures are now copied into the Flutter
asset bundle with a checked catalog. Repository validation compares the bundled
bytes with `native/media_core/testdata`, validates RIFF/WEBP headers and declared
byte lengths, and requires all three entries to remain reachable from the app.

### App navigation and local import

The app now opens a demo home instead of entering the 100-page static chapter
automatically. Separate entries open the static reader, a bundled Animated WebP
catalog, and the platform file selector for a local `.webp`. Local files are read
through `XFile` bytes, so the preview does not depend on a manifest or direct I/O
in the reader package. `file_selector` 1.0.3 preserves the current Dart 3.6 SDK
floor.

### Native preview path

The Animated WebP preview creates a `NativeSource`, appends and seals the selected
bytes, validates the pinned libwebp runtime, creates a typed native cursor, copies
`PixelFrame` RGBA bytes into a Flutter `ui.Image`, and follows native duration and
loop metadata. RGBA is premultiplied before presentation. The user can switch to
Flutter's codec for comparison. Missing or invalid native libraries cause an
automatic Flutter-codec fallback instead of a blank page.

### Next iteration

1. Replace the diagnostic RGBA copy with the Android `SurfaceProducer` texture
   registry and serial native blit worker.
2. Connect reader page roles to the real native player instead of the standalone
   preview route.
3. Add import of a local directory/CBZ chapter and persist the resulting catalog.
4. Add Android device tests for lifecycle-safe output retirement and overlap.

## 0.15.0-dev.15 — pinned libwebp source builds

### Source ownership

Host and Android builds no longer accept prebuilt per-ABI libwebp directories.
`native/libwebp.lock` pins libwebp 1.6.0 to the official WebM repository and
commit `4fa21912338357f89e4fd51cf2368325b59e9bd9`. `fetch_webp.sh` creates a
shallow detached checkout and verifies the exact commit before any native build.
A local source override is rejected unless it is the pinned git checkout or the
caller explicitly enables an unpinned development source.

### Reproducible host and Android builds

`build_webp_host.sh` and `build_webp_android.sh` use the upstream CMake project
with only libraries enabled. Build and install outputs are isolated below
`.deps` by source version, platform, ABI, mode, and link type. Android uses the
NDK CMake toolchain for arm64-v8a, armeabi-v7a, and x86_64. `media_core` links
those generated artifacts; no downloaded binary archive is accepted.

Android defaults to PIC static archives linked into `libmedia_core.so`, avoiding
versioned shared-library SONAME dependencies in `jniLibs`. An explicit shared
mode remains available for diagnostics. Android assets include upstream COPYING, PATENTS, and exact
source provenance.

### CI and local checks

Host C smoke and Rust tests now build the pinned source first. CI no longer
installs a distribution `libwebp-dev` package and has a dedicated Android-native
job that builds all configured ABIs. Flutter-only split APK CI uses
`ZIC_ANDROID_NATIVE=0`; normal `build_android.sh` includes native media by
default. ABI v5 also exposes the linked decoder and demux versions; the Dart
bridge reports whether both equal the pinned 1.6.0 packed version.

### Next iteration

1. Add the Kotlin `SurfaceProducer` texture registry and serial blit worker.
2. Pass retained frame handles through JNI without MethodChannel pixel copies.
3. Separate texture creation, first blit, present, and lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

## 0.14.0-dev.14 — statically typed cursor outcomes and Android native packaging

### Cursor contract repair

`FrameCursor.decodeNext()` no longer returns nullable frames. `CursorStep`
separates a produced frame, an incremental wait, and terminal end-of-stream.
`CursorBinding` carries the mandatory frame cursor and an optional loop view.
`DecodeSession` stores that binding directly and no longer performs a runtime
`is LoopCursor` check or uses `null` to infer native state.

A non-loop cursor can now report a real terminal end. A looping cursor receives
rewind only after an explicit end step and an empty holder. Cancellation still
disposes a frame returned after the demand was superseded.

### Incremental decoder hardening

The libwebp C smoke test now parses every byte prefix of all three deterministic
fixtures and rejects false parse errors or complete frames without fragments.
The Rust ABI test appends the primary animation one byte at a time, drains only
real complete frames, and verifies that cursor indexes never advance on
`NeedMoreData`.

### Android native packaging

`tool/build_android_native.sh` builds `media_core` for arm64-v8a,
armeabi-v7a, and x86_64 using the Android NDK and per-ABI libwebp libraries. It
packages `libmedia_core.so` and shared libwebp dependencies into Flutter
`jniLibs`, or supports PIC static archives when requested.
`tool/check_android_native.sh` validates the produced layout. The split APK
script invokes native packaging whenever `ZIC_ANDROID_WEBP_ROOT` is configured.

### Next iteration

1. Add a Kotlin `SurfaceProducer` registry and a dedicated serial blit worker.
2. Pass retained native frame handles to Android through JNI without copying
   RGBA through MethodChannel.
3. Separate texture allocation from first blit and add lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

## 0.13.0-dev.13 — animation metadata and loop semantics

### Native cursor metadata

ABI v4 adds frame count, WebP play count, metadata completeness, zero-based
cycle, rewind, and frame-cycle accessors. The native decoder refreshes metadata
from every successful partial demux. Rewind is accepted only after a real
end-of-stream result. A play count of zero is infinite; a positive value limits
the total number of cycles. Rewind resets canvas composition and frame numbering
while retaining source ownership and epoch.

A deterministic `finite_loop.webp` fixture declares two frames and a play count
of two. Rust tests cover one allowed rewind and the final rejected rewind. The
C smoke test validates frame count and loop metadata independently through the
installed libwebp headers and library.

### Session loop ownership

The media contract now exposes `AnimationInfo` and the optional `LoopCursor`
capability. `DecodeSession` keeps non-looping fake/fallback cursors unchanged.
For a looping cursor, it rewinds only after EOF and only when the holder is
empty, so a deeper watermark cannot introduce duplicate frame indexes while an
older cycle is still retained. Infinite content continues with a new cycle;
finite content enters the explicit `DecodeState.ended` state once its play count
is exhausted.

Decode snapshots expose animation metadata and cycle. Every successful rewind
emits `animationLoop` telemetry.

### Next iteration

1. Add Android native build/package automation for arm64-v8a, armeabi-v7a, and
   x86_64, including libwebp dependencies.
2. Add a Kotlin `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to an Android texture uploader without sending
   RGBA bytes through MethodChannel.
4. Add lifecycle-safe texture retirement and background/foreground tests.

## 0.12.0-dev.12 — real incremental Animated WebP decode

### Native decoder

The existing ABI v3 cursor now performs real WebP work instead of returning
`unsupported`. It reparses the authoritative committed prefix with
`WebPDemuxPartial`, requests the next one-based frame, and only decodes when the
iterator marks that frame complete. A partial frame returns `needMoreData`
without mutating the canvas or advancing the frame index.

Complete frame fragments are decoded to straight RGBA with libwebp, scaled to
the physical `DecodeId` target, and composed onto a persistent target-size
canvas. Composition implements `WEBP_MUX_BLEND`, `WEBP_MUX_NO_BLEND`, and
previous-frame background disposal. The immutable composed canvas becomes the
retained native frame payload, with frame duration propagated in microseconds.

The decoder currently performs one pass. Session-level loop count and cursor
reset semantics remain explicit next work rather than being hidden in the
native cursor.

### Native dependency boundary

`build.rs` links `webpdemux` and `webp`. Desktop builds use system libraries;
custom/Android builds may set `ZIC_WEBP_LIB_DIR` and optionally
`ZIC_WEBP_STATIC=1`. The Flutter Android package does not yet bundle these
transitive native libraries.

A deterministic two-frame lossless Animated WebP fixture is checked into the
native test data. Rust tests validate partial-prefix waiting, real red/green
RGBA output, duration/size metadata, and end-of-stream. A C smoke program also
compiles and runs directly against the installed libwebp to validate the
headers, partial demux behavior, fixture metadata, and fragment decode.

### Next iteration

1. Add animation metadata and loop/repetition semantics to the cursor/session
   contract.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Package media-core and libwebp per Android ABI and connect a no-copy uploader.
4. Replace baseline software frame scaling with decoder-native scaling where
   platform profiling proves it beneficial.

## 0.11.0-dev.11 — explicit playback capability and native frame ABI

### Requested fix

`ReaderBinding` no longer derives a local `playback` variable from a value typed
as `Coordinator`. Its constructor now requires the demand and playback
capabilities separately:

```dart
required Coordinator coordinator,
required PlaybackCoordinator playback,
```

The binding stores `_coordinator` and `_playback` with their actual interface
types. The app and tests explicitly pass the same live/fake object when it
implements both contracts. A regression test also supplies two separate
objects, proving the binding does not depend on a runtime type check.

### Native cursor and frame ownership ABI

The Rust media core ABI is now version 3. `ByteSource` uses shared source state;
a cursor clones that state, so releasing the source handle cannot leave an
existing cursor with a dangling pointer. Source reset still advances the epoch,
and cursor decode rejects stale epochs.

Added stable C/Rust/Dart symbols for:

- cursor create/free/epoch/decode-next;
- frame retain/release;
- frame epoch/index/size/duration/format/length/data access.

A frame handle owns an `Arc` to immutable frame data. `retain` creates another
independent handle, and the data remains valid until the final handle is
released. Dart wraps this as `NativeCursor`, `NativeFrame`, and
`NativeCursorFactory`; copied byte access does not expose a long-lived raw
pointer to application code.

The ABI intentionally returns `unsupported` for sealed WebP decode until the
real WebP decoder is linked. It does not synthesize frames or advance cursor
state. Unknown/incomplete input returns `needMoreData`.

### Source failure status

Added `SourceStatus.failed` at ABI index 6 and mapped lock/native failures to a
structured source failure. `Ingress` disables only the derived native source;
the durable artifact remains authoritative.

### Tests and gates

- Added explicit demand/playback contract coverage for `ReaderBinding`.
- Added native cursor factory contract coverage and ABI enum/version checks.
- Added Rust tests for source/cursor shared ownership and retained frame handles.
- Repository validation now requires the explicit playback field and every new
  cursor/frame ABI symbol in Rust, C, and Dart.

### Next iteration

1. Link a real incremental Animated WebP decoder behind the cursor ABI.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to the Android uploader without copying through
   MethodChannel.
4. Resolve frame budgets from live device memory and thermal telemetry.

## 0.10.0-dev.10 — reader binding and frame budgets

### Requested fix

- Replaced `ReadingDirection.leftToRight` in
  `pipeline/test/viewport_phase_test.dart` with the canonical `ltr` enum value.
- Added a repository regression gate that rejects the stale long-form value.

### Reader runtime binding

Added `ReaderBinding` as the application composition boundary for one reader
session. A single `ReaderObs` now drives `PipelineController`, demand
reconciliation, `ViewportResolver`, and playback synchronization. The demo app
uses this binding instead of wiring only the demand callback.

`Coordinator` remains the demand contract. `PlaybackCoordinator` is a separate
capability implemented by both live and fake coordinators, so non-playback
coordinators do not need dummy methods.

### Decoded/output budgets

Added `FrameBudget` and `FrameBudgeter` with independent decoded and renderer
output byte limits. Each limit has a current-page reserve. Non-current sessions
may use only the remainder and are trimmed in ascending demand priority.
Current-page resources are not silently discarded when the current page alone
exceeds a limit.

`FrameHolder` can now trim by bytes while respecting active claims.
`UploadSession` exposes output bytes and only trims an output when no present
claim exists. `LiveCoordinator` enforces the budget after reconciliation,
decode completion, and upload completion, and emits `frameBudget` telemetry
when bytes are released.

### Next iteration

1. Add native cursor/frame ABI and frame-handle retain/release ownership.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Resolve frame budgets from device memory/thermal telemetry instead of fixed
   construction-time limits.

## 0.9.0-dev.9 — split APK and viewport playback gate

### Requested fixes

- Removed the two trailing commas inside `SourceStatus.values[...]` index
  expressions in `bridge/native_source.dart`.
- Android APK builds now go through `tool/build_android.sh` and always use
  `--split-per-abi`.
- CI builds split debug APKs instead of a single fat APK.

### Viewport playback integration

Added `ViewportResolver` and `ViewportState` with four phases:

- `idle`;
- `dominant`;
- `overlap`; and
- `continuous`.

For discrete PageView navigation, playback freezes only while both pages have a
significant overlap. It resumes as soon as either page becomes dominant. For
continuous/custom scrolling, presentation remains frozen until the interaction
returns to idle.

Added `PlaybackGate` and `LiveCoordinator.syncPlayback()`. The gate applies
freeze/resume changes only when state changes, freezes a running page before it
leaves the tracked viewport, and does not restart timers repeatedly for
identical viewport observations.

### Build and regression gates

- Added `tool/build_android.sh [debug|profile|release]`.
- Added `make android-apk`.
- `tool/check.sh --require-toolchains` now also builds split debug APKs.
- Repository validation checks split APK configuration, native source index
  syntax, viewport exports, and coordinator playback integration.

### Next iteration

1. Connect Reader viewport reports to `ViewportResolver` and the live pipeline
   binding used by the app.
2. Add decoded/output byte budgets with a reserved current-page allocation.
3. Implement native cursor/frame ABI and frame-handle ownership.
4. Add Android `SurfaceProducer` texture registry and serial blit worker.

## Android library shell and persistent shelf state

The app now exposes Home and Bookshelf as primary destinations. Home contains
update and reading-history card rails; Bookshelf contains source/category
filters, management deletion, recent/title/page-count/custom sorting and durable
custom reordering. Existing static/WebP/native diagnostics remain available
below the product sections for regression work.

SQLite schema version 3 persists custom categories, shelf/liked/collected flags,
category membership, source kind, custom order and explicit chapter read state.
The in-memory store implements the same contract. Existing version-1 databases
migrate in place.

Cover cards load their first page through the local-media byte boundary and use
`Image.memory`, so animated WebP/GIF covers can animate. A reusable download
waterline supports percent and completed/total page count. Details UI implements
preference toggles, chapter order reversal, read dimming and right-swipe restore
unread. Local imports without metadata continue to open Reader directly on long
press.

## 3.12 Android source networking and copyable diagnostics

Flutter platform hosts remain generated artifacts, but their product capabilities are now configured
by repository-owned tooling. `tool/configure_platforms.py` idempotently inserts the Android Internet
permission into the generated main manifest. Bootstrap, Android build and the repository Android run
entry all invoke this step, so release networking does not depend on Flutter's development manifest.

`HttpTransport` still owns ordinary HTTP byte ingress and does not move networking into Widgets. Its
default client can now use an explicit connection timeout and user agent, and socket failures include
OS error text and errno. `MangaDexSource` applies one bounded retry only to `ErrorCode.network`; source,
format and size failures are never retried as network transients.

The source UI captures the original error, `Failure.cause` and stack trace. Primary failures use a
bounded `SelectableText` diagnostics surface with long-press selection and explicit clipboard copy.
A failed host lookup is described as either missing Android application permission or a system DNS /
proxy / VPN path difference; browser reachability is not treated as proof that the App resolver works.


## 3.13 Authoritative chapter-download management

`ChapterDownloadService` now exposes a task stream rather than only a blocking command. Each
`ChapterDownloadSnapshot` carries source-composite chapter identity, comic/chapter labels,
completed/total pages, received/total bytes, a bounded phase and copyable failure text. The
persistent implementation computes this projection from the existing `DownloadRegistry`,
`DownloadSession` and promoted artifacts; it does not create a parallel downloader or progress
store. Terminal phases remain authoritative while late session callbacks drain.

Home, reading history and Bookshelf reuse the same `ComicCoverCard` and aggregate snapshots by exact
`sourceId + comicId`. Incomplete work dims the cover and displays a bottom-up completion waterline,
percent and completed/total pages. Complete coverage restores the original cover and shows only a
compact offline badge. A top-level Download Manager exposes per-chapter cancel, retry and confirmed
offline artifact deletion, with page/byte progress and selectable/copyable failure details. Offline
artifact deletion deliberately retains the saved comic, imported chapter metadata, reading progress
and explicit read state.

The memory fallback implements the same lifecycle and owns full page bytes before completion. Tests
cover progress publication, cancellation with retained partial progress, retry to completion and
manager deletion. Missing covers now fail asynchronously into a placeholder instead of throwing from
a Widget build; details mark chapters read before opening Reader, avoid duplicate titles, and expose
stable source-management, sorting, category-move and retry controls.
