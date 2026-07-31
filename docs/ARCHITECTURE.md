# zic Architecture

## 1. 总览

`zic` 使用 Flutter 应用层、Dart 资源策略与 session 编排、Rust 媒体内核、Kotlin/Swift texture 桥接的混合架构。

```text
Reader UI / Catalog UI
        |
        v
ReaderController + ReaderViewportReporter
        |
        v
PipelineController
  |       |        |
  |       |        +--> Telemetry / FeatureBuilder
  |       +-----------> Window + Ranker + PolicyGuard
  +-------------------> HeuristicPolicy / AdaptivePolicy
        |
        v
DemandPlan(download/decode/upload/keep)
        |
        v
Coordinator
  |          |           |            |
  v          v           v            v
NetLane DecodeLane UploadLane MaintenanceLane
  |          |           |
  v          v           v
Transport  DecodeSession TextureRegistry
  |          |
  v          v
Artifact   Rust Media Core
```

## 1.1 首页冷启动与文件型封面路径

```text
runApp(_BootstrapApp)
  -> Flutter startup surface
  -> open library/index/cache services
       -> one bulk read-state query
       -> one index-only download-status projection
       -> no eager DownloadSession restore / page-file stat
  -> Home visible cards
       -> local plain file ---------> FileImage
       -> durable cover locate ------> FileImage
       -> source miss -> bytes -> atomic cache file -> FileImage
```

持久响应 store 首次命中时读取一个 `response-manifest-v1.json`，之后按完整 key 在内存索引中定位；逐项 JSON 只用于崩溃恢复和旧布局迁移。LRU touch 聚合后批量写回。

`ResourceCacheByteStoreFileAccess` 只暴露经过完整 key、TTL 和长度校验的只读文件引用。它避免 warm cover 进入 Dart heap，但不宣称平台 decoder 内部无复制。`content://`、动画与 Reader demand 仍走各自受控 adapter。书架 read-state 使用单次批量查询；离线徽标使用一次 SQLite index projection，不创建 session、不读取或 stat 页面文件。精确页面命令才 materialize/restore 对应 session。
普通本地静态图片的 engine-facing owner 只有 Flutter `Image` 本身。`LocalImagePlayer` 不再额外 `resolve` 同一 `FileImage` 来观察 ready；实际 `frameBuilder` 是唯一首帧通知。这样文件路径只建立一个 `ImageStream`，测试可独立验证“不进入 Dart 整文件字节路径”，而平台 decoder 呈现由单独用例负责。

## 1.2 冷启动 Reader promoted-artifact 路径

```text
ArtifactCacheStore.read(exact DownloadId)
              | shared immutable Future
              +--> Reader media decode (first-frame critical path)
              +--> ArtifactCacheTransport --64 KiB chunks--> replacement DownloadSession
                                                       -> seal -> promote
```

`PromotedArtifactReadPool` 属于 `downloads`。权威 `DownloadSession.beginRun` 是最早的读取启动信号，因此持久 artifact 可在替代 session 恢复临时 workspace 时并行读取；页面只能加入同一精确 Future，不产生 demand、不选择页面、不保留 decoded/texture 状态。观察者注册会立即接收当前 snapshot，避免已开始 run 的转换丢失。缓存读取失败时 transport 回退 source，页面等待该 session。Flutter animated target-only re-decode 保留最后呈现帧，直到替代帧 present。

- Mihon/Venera runtime compatibility: a Mihon APK and its selected 1.4/1.6 Source ABI dex asset must be exact-length/SHA-256 verified and non-writable before a child-first loader observes them. `eu.kanade.tachiyomi.*` comes only from that versioned child loader; AndroidX Preference and other common libraries remain parent-first so Android resources are merged. Venera accepts page-number `load` and cursor `loadNext`, preserves legacy global `res` script behavior, uses a 55-second bounded invocation limit, and routes ordinary HTTP(S) covers plus transient page tokens through the isolated resource bridge.
- External chapter identity: Mihon keeps every real chapter returned by the selected source ABI and retains its live `SChapter` object for the runtime session. Only an empty upstream catalog may synthesize one `正文` chapter. After process restart, the opaque identity is resolved against a freshly normalized catalog; no manga-level URL fallback may replace a non-empty multi-chapter catalog.
- External source settings: Mihon Preference objects and Venera `settings` definitions both terminate at `ConfigurableComicSource`. The isolated runtime owns plugin preference/storage reads and writes; Presentation renders normalized toggle/text/select/multi-select/action values and may request an explicit runtime restart, but never receives SharedPreferences or JavaScript objects.
- External source authentication: Venera `account` terminates at `AuthenticatableComicSource`. Presentation may collect credentials or host a login WebView, but only a bounded snapshot of final URL/title/Cookie/localStorage crosses the bridge; the isolated runtime invokes source validators, persists account state and performs logout. Cookie fields preserve source-declared order.
- Mihon chapter discovery: a combined detail result with no chapters is not authoritative emptiness. The driver probes detailed/original manga objects through compatible public or inherited chapter-list APIs and adapts Future, RxJava 1 and RxJava 2/3 blocking results. Empty/unsupported candidates continue probing, but real failures are aggregated and returned. A gallery chapter is synthesized only after the complete catalog is empty and a non-empty page list has been preflighted; its detail row carries the verified page count.
- External media hints and covers: Mihon cover locators are normalized into source-owned resources with source headers; Mihon/Venera page messages may carry WebP/GIF/etc. hints, but byte sniffing and codec validation remain authoritative. Unknown opaque tokens are not guessed.
- Venera HTTP compatibility: the sandbox bridge supplies the bounded WebView user agent when a source omits one and owns at most eight redirect hops. Cookies are committed after every hop, relative locations are resolved, and credentials are stripped across origins; URLConnection and DNS-fallback OkHttp do not auto-follow independently.
- Progressive Mihon page metadata: catalog `pageCount == 0` means unknown. Remote details may preflight up to two chapters concurrently through the cached source adapter and replace the current manifest with resolved counts; this is metadata projection only and creates no alternate page-byte cache.
- Reader transfer publication: synchronous DownloadSession snapshots are coalesced and published after the current build frame, so Presentation observes progress without mutating a notifier during build.
- Source-management projection: installed plugin records and enabled source instances are separate views. The root page groups enabled sources into Native/Mihon/Venera sections and folds Mihon language variants there. Each ecosystem installation page switches between Installed and Repository tabs; device Mihon discovery exists only in Installed and has independent refresh/error state.
- Non-blocking durable composition: `_BootstrapApp` mounts an in-memory usable app first, opens durable library/cache/download services asynchronously, and swaps composition after readiness. Home restoration is represented by a non-modal top sync indicator rather than a blocking route.
- Reader input and streaming: at scale 1, `PageView` owns horizontal paging and no scale recognizer is installed. Animated playback controls require an actual animation capability. Remote WebP binds the native incremental cursor to the authoritative `DownloadSession.ingress.source`; `needMoreData` waits for committed-byte advancement, and UI projects restored-prefix and current-network progress without owning transport.

## 2. 仓库结构

```text
zic/
  apps/
    app/                     Flutter 应用入口

  packages/
    domain/                  领域实体、identity、值对象
    catalog/                 书架、章节、来源抽象与缓存装饰器
    plugin_host/             外部来源信任、权限、隔离与 session 生命周期门禁
    resource_cache/          统一响应缓存预算、TTL、合并与失效
    downloads/               页面 artifact 下载与整本队列核心
    downloads_bridge/        网络/供电与队列持久化平台适配
    reader/                  Reader UI、viewport、交互报告
    reader_runtime/          Reader session composition、transport/workspace adapter
    pipeline/                policy/window/ranker/demand
    sessions/                download/decode/display session
    transport/               网络、本地文件、resume
    storage/                 artifact、cache index、SQLite 与持久目录库
    storage_bridge/          Flutter 应用支持目录与 storage 后端装配
    telemetry/               指标、事件、trace、设备状态与确定性切页回放分析
    bridge/                  FFI、native source/cursor/frame handle
    texture_bridge/          Flutter texture 契约与 Android 插件
    local_media/             本地图片模型、格式嗅探、桌面目录枚举和平台 facade
    local_media_ui/          本地图片导入/预览与 WebP Flutter/native 播放 UI
    local_media_bridge/      Android SAF document tree/content URI 插件
    runtime_bridge/          Android 网络计费与供电状态信号插件
    testkit/                 fake clock/source/decoder/trace

  native/
    media_core/              Rust 增量解析、解码、帧内存和 Android blit

  tools/
    bench/                   解码、滚动、缓存和回放基准
    replay/                  policy 日志回放

  docs/
  .github/workflows/
```

## 3. 分层和依赖规则

### 3.1 Presentation

包含：

- LibraryScreen
- ReaderScreen
- ReaderScaffold
- PageViewport
- Settings

职责：

- 展示状态；
- 报告 current/stable index；
- 报告 dragging/scrolling/jumping/idle；
- 报告 viewport coverage、运动方向和目标 asset key；
- 获取 ImageProvider 或 texture handle。

禁止：

- 创建网络连接；
- 直接预缓存页面；
- 直接创建/销毁 decode session；
- 清理 artifact；
- 根据 Widget 生命周期推断物理资源生命周期。

### 3.1.1 App composition facades

`apps/app/lib/reader_runtime.dart` 与 `webp_demo.dart` 仅是兼容导出，不实现 session、transport、decode 或媒体探测。

- `packages/reader_runtime` 负责把 Reader application/controller 与 session、transport、workspace、artifact handoff 装配起来，并显式依赖 `media.SourcePool`。
- `packages/local_media_ui` 负责本地图片导入、预览和 WebP presentation；WebP prefix 元数据来自 `packages/media`，native cursor/texture 仍通过既有 bridge。
- App production dependencies 不直接声明 `pipeline/sessions/storage/transport`；这些低层依赖只能由 composition package 所有。测试可在 `dev_dependencies` 中直接引用其契约。
- App facade 不得再次增长为实现文件。单个 local-media UI 实现文件上限为 1600 行，继续增长时必须按状态所有权进一步拆分。

### 3.1.2 根导航与设置投影

根导航固定为 `首页 / 书架 / 漫画源 / 杂项`。`杂项`承载快捷设置、完整设置入口、关于和 Debug trace，不把诊断控件重新塞回 Home 主线。

`AppPreferencesController` 只持有小型用户选择；文件读写由 composition 通过 `storage_bridge` 注入。设置页可以调用既有 application facade：书架默认值更新既有投影，Reader 默认模式/沉浸值进入既有 Reader composition，整本下载策略调用持久队列，缓存维护调用 `ResourceCacheCoordinator`。设置页不得直接创建 transport、访问插件 Cookie/存储、遍历或删除 artifact 文件。

`DebugTraceLog` 是有界 `TraceSink` 读模型。trace producer 仍属于 startup、Reader、pipeline、download 等原 owner；Presentation 只能观察、复制、清空或暂停记录。 event list 可立即更新，但 observer 通知必须在下一安全帧合并，允许 Reader build 中记录 trace 而不触发同步重建。

每漫画 Reader 设置由 `AppPreferencesController` 以 `sourceId + comicId` 小型 map 持久化，并通过独立 projection 转换成 `ReaderSessionSettings`。它只能覆盖方向、纵向拼接和自适应开关；不能保存页面字节、artifact、下载状态、插件 session 或 pipeline demand。

### 3.1.3 外部插件仓库 UI

每个生态的安装管理页固定使用顶部 `Installed / Repository` 两个 ownership projection，同一时刻只展示一个整页内容。Mihon device discovery 只属于 Installed，并拥有独立 refresh/busy/error 状态；Repository 只负责索引、安装与更新。主漫画源管理页只投影已启用来源并按 Native/Mihon/Venera 分段。Mihon language family 的默认折叠发生在这个启用来源投影，不发生在 repository；catalog identity、pluginId、签名、payload、设置、启用状态和 activation session 始终独立。

### 3.2 Application

`ReaderController` 管理阅读会话：

- 打开章节；
- 页面模式；
- 当前进度；
- 章节边界；
- 向 PipelineController 提交 ReaderObs。

它不拥有 transport 或 decoder。

### 3.3 Policy/Pipeline

`PipelineController` 是唯一资源策略入口。

输入：

- ReaderObs；
- SessionSnapshot；
- DeviceSnapshot；
- NetworkSnapshot；
- ContentMetadata；
- PolicyModelSnapshot。

输出：

- `DemandPlan`。

内部组件：

- `RoleResolver`
- `ResourceRanker`
- `HeuristicPolicy`
- `AdaptivePolicy`
- `PolicyGuard`
- `DemandDiff`

### 3.4 Session

`Coordinator`：

- 维护 DownloadSession、DecodeSession 和 DisplayLease registry；
- 合并相同 identity 的任务；
- 将任务提交给独立 lane；
- 执行 demand reconcile；
- 保证 detach、retain、evict 和 dispose 语义。

Session 不依赖具体 Widget。

### 3.5 Transport/Artifact

Transport：

- HTTP、本地文件或归档字节源；
- range/resume；
- writer lease；
- chunk offset 校验；
- seal/promote。

Artifact：

- partial 文件唯一写入者；
- committedLength；
- checksum；
- partial → final 原子 handoff；
- 不负责网络调度。

### 3.6 Format Runtime

统一接口：

```dart
abstract interface class CursorFactory {
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  });
}

abstract interface class FrameCursor {
  Future<CursorStep> decodeNext();
  void dispose();
}

// CursorStep explicitly distinguishes frame, needMoreData, and end.
// CursorBinding carries an optional non-owning LoopCursor capability.
```

具体实现：

- Animated WebP：Rust incremental source + cursor。
- GIF v1：artifact + external snapshot runtime。
- GIF future：Rust incremental cursor。
- 静态图片：Flutter codec 或平台静态解码路径。

### 3.7 Renderer

Android：

- `texture_bridge` 创建 `SurfaceProducer`，每次绘制重新获取当前 `Surface`；
- 一个 engine attachment 只拥有一条串行 native blit lane；
- Dart 在 MethodChannel 调用期间 retain 一份 frame owner；
- 平台成功呈现后另行 retain 当前 texture frame，直到下一帧、resize 或 release；
- `onSurfaceAvailable` 只重绘平台持有的当前帧，不借用已归还给 Dart 的 handle；
- engine detach 与 `scheduleFrame` 通过生命周期锁串行，detach 后不再请求 engine frame；
- present deadline 使用提交后的相对预算，统一基于平台单调时钟计算；
- texture create、首次 blit、resize 和 release 是独立操作；
- Flutter 侧以源画布 `AspectRatio` 建立 contain paint box，再让 `Texture` 填充该 box，禁止 texture 直接吃满 Reader/预览 viewport。

Dart presenter 输出：

- `queueMicros`、`uploadMicros`、`deadlineMissMicros`；
- `frameBytes`、`textureBytes`、`inFlightBytes`；
- `sessionId`、`decodeIdentity`、`demandRevision`、`epoch` 归因上下文；
- platform failure 的 fallback telemetry。

Reader 媒体页将 native decode、frame preparation、texture upload、present 与
fallback 写入同一 monotonic trace。`ReaderTransitionTraceAnalyzer` 只读重放 page transition、
artifact source、decode/upload、present、first-frame 与 host lifecycle，输出可测阶段耗时和缺失证据；
它不得创建 demand、保活页面或调整缓存。`ReaderBinding.revision` 是输出层只读的
需求版本来源，播放器不得自行生成与 PipelineController 无关的 revision。

WebP 打开与 native 实验启动是两个不同状态：页面先完成 Dart 容器校验并使用
Flutter codec。Reader 和文件夹切换隐藏 native 控件；只有独立预览中显式选择且
确认后才建立 FFI source/cursor 和 Android texture。这使普通阅读与批量切换共享
安全路径，同时保留可观测的 native 诊断入口。

本地图片文件夹导入位于 App/catalog 边界，不进入 `reader` package。桌面和普通 IO
平台在后台 isolate 中递归枚举文件并探测前 64 字节；Android 不再把 SAF tree URI
转换为原始路径，而由 `local_media_bridge` 持有 `ACTION_OPEN_DOCUMENT_TREE` grant，
通过 `DocumentsContract` 递归枚举，并用 `ContentResolver.openInputStream` 读取文件头
和当前页面字节。两条路径都不以扩展名作为类型依据。签名层只负责最小 magic-byte
格式嗅探，完整 WebP parser 或 Flutter codec 负责最终有效性。

输出不可变的 `PickedImageFolder`；每个 `PickedImage` 拥有相对 `displayName`、显式
`sourceId`、兼容 `XFile` 和 byte-loader。Android `sourceId` 是持久授权的 content URI，
不得再经 `Uri.file` 或 `dart:io File` 解释。

App/catalog 边界将选择结果归一化为可序列化的 `ImportedChapterRecord`，再生成稳定的
`ChapterManifest`。平台 byte-loader 通过 `LoaderTransport` 进入生产
`LiveCoordinator -> DownloadSession -> promoted artifact` 链，Reader 页面只能从该
artifact 读取。目录页不再维护独立 index；上一页、下一页和菜单跳转都提交
`ReaderController.requestPage`，由 `ReaderView` 消费。离屏页面销毁会取消等待 artifact
promotion 的 token 和 snapshot listener，避免切页后继续占用目录内容流。
临时 Reader cache workspace、artifact 文件读取和递归清理由 `packages/storage`
的 `EphemeralCacheWorkspace` 持有；`apps/app/lib` 不导入 `dart:io`，只装配 workspace、
session 和 Widget。
目录扫描得到的 byte length 会进入 `PageAsset`；`LoaderTransport` 的 validator
同时包含 source revision、长度和完整内容 hash，避免同 URI、同长度内容替换后续接到
旧 partial。

导入目录的可序列化记录由 `catalog/ImportedLibraryStore` 持有；SQLite 实现位于
`packages/storage`，Flutter 应用支持目录解析位于 `packages/storage_bridge`。App 只注入
store、展示目录库并提交进度。Reader 页变化写入 `ReadingProgress`，重新打开目录时以
chapter/comic identity 校验后恢复页码与 paged/continuous 模式。
目录刷新由 `local_media` 重新扫描持久化 directory identity；Android bridge 使用原 SAF tree URI，
桌面使用原路径。`ImportedLibraryStore` 在 upsert 时按旧当前页的 source identity 迁移进度，
避免前置页面新增或删除导致阅读对象漂移。

`catalog/LibraryComic` 是 `SavedComicRecord` 与持久化章节上的只读漫画级投影，聚合身份为
`sourceId + comicId`。`SavedComicRecord` 可在零章节时保存整部漫画元数据和轻量来源目录；
章节记录继续拥有页面 manifest、进度和 read state。Home 与 Bookshelf 只消费该投影。

详情保留两个状态所有者：远程页加载完整上游目录，本地页读取保存的目录快照和持久章节。
两页共享呈现组件并通过集中路由选择，但不会合并生命周期。上游目录刷新不会自动下载章节；
点击章节才确保 Reader manifest，行尾下载才创建持久离线 artifact。聚合不接管 source、
Reader 或 DownloadSession 所有权，也不隐藏 chapter identity。

非 Android：

- Flutter `ui.Image` renderer；
- Android texture 创建、上传或生命周期操作失败时回退 Flutter codec；
- iOS texture path 在 v1.0 前补齐。

### 3.8 本地媒体与预览测试边界

本地选择结果使用显式产品对象：

```dart
final class PickedWebp {
  final String displayName;
  final XFile file;
}
```

`displayName` 是路由标题契约，不能由测试后续重新推断，也不能依赖
`XFile.fromData` 在不同平台是否保留 `name`。测试分为四个边界：

1. picker：选择、取消和 `PickedWebp` 归一化；
2. route：入口到预览页面及标题传递；
3. validation：纯字节 WebP 容器校验；
4. preview state：`loading`、`ready`、`invalid` 显式状态和语义 key。

这些测试不把辅助文案、状态栏或布局节点当作页面身份，也不通过固定
`pump(Duration(...))` 猜测异步完成。

### 3.9 Reader 媒体页面

`ReaderView` 接受可选 `ReaderPageBuilder`。默认仍渲染静态 asset；媒体页面
可以返回真实播放器，并在实际首帧呈现后调用 `reportFirstFrame`。页面 host
对同一 asset 只记录一次首帧，并在 asset identity 改变时重置。

App composition 使用 `ReaderBinding -> LiveCoordinator -> DownloadRegistry`，不再
用 `FakeCoordinator` 模拟需求。manifest 的 `source/comic/chapter/page/revision/URI`
生成唯一 `DownloadId`；播放器只在对应 `DownloadSession` promoted 后读取 final
artifact。因此 Reader demand、下载 telemetry 和最终显示字节共享同一身份。asset
URI 通过只读 AssetBundle transport 进入相同 DownloadJob，file/http(s) 则使用
IoTransport。

`DownloadSession` snapshot listener 是只读观察契约：立即提供当前状态，并在
receiving/sealed/promoted/failed/disposed 等状态变化时通知；观察者异常不能破坏
权威 session。播放器加载持有 `WebpLoadToken`，离屏销毁时先取消 token，使等待
promotion 的 listener 在 `finally` 中立即解除。viewport target 更换或 Reader 销毁
前，`ReaderBinding.detach` 必须把旧 plan reconcile 到 empty，之后再取消
coordinator lane 并释放 artifact registry。

当前阶段只把生产 ingress/artifact 接入 Reader；可见 WebP 仍由 Flutter codec
解码和呈现。后续 DecodeRegistry/UploadRegistry 接入必须复用相同 DownloadId、
epoch、revision 和 deadline telemetry，而不能重新建立预览专用身份。

## 4. 核心领域模型

### 4.1 Identity

```dart
final class ContentId {
  final String sourceId;
  final String comicId;
  final String chapterId;
  final String pageId;
}

final class DownloadId {
  final ContentId content;
  final String sourceRevision;
  final Uri canonicalUri;
}

final class DecodeId {
  final DownloadId download;
  final int physicalWidth;
  final int physicalHeight;
  final PixelFormat pixelFormat;
  final RendererKind renderer;
}
```

规则：

- Download identity 可复用编码字节。
- Decode identity 不能复用 cursor、播放时序和 frame holder。
- 旋转或真实物理尺寸变化创建新的 DecodeId。
- safe-area inset 变化不创建新 identity。
- 物理解码尺寸按固定粒度对齐，默认 8 像素。

### 4.2 Epoch

每个可增长 source 有单调递增 epoch。

以下操作必须增加 epoch：

- source reset；
- 下载重新开始；
- identity rebinding；
- partial 被判定损坏并重建；
- decode source 替换。

所有异步结果携带创建时 epoch。提交前必须匹配当前 epoch。

### 4.3 Lease 与 Claim

- `VisibleLease`：页面当前被显示层引用。
- `DownloadDemandLease`：策略要求下载。
- `DecodeDemandLease`：策略要求解码。
- `UploadClaim`：帧正被上传或提交。
- `WriterLease`：artifact 唯一写权限。

物理驱逐条件：

```text
no visible lease
AND no download/decode demand
AND no active decode/upload claim
AND no active writer
AND no retained receiving policy
```

## 5. 页面资源角色

```dart
enum PageRole {
  current,
  transition,
  next,
  previous,
  near,
  far,
  detached,
}
```

### current

- 最高 network/decode/upload 优先级；
- 保留最低 frame depth；
- 任何模型不能降低最低保障。

### transition

- 在翻页中点前根据 viewport coverage 提升；
- 可提前下载、解码和创建 texture；
- overlap 阶段可冻结 present；
- dominant 后立即恢复。

### near/next/previous

- 根据方向和反向概率分配编码和首帧需求；
- current 水位不足时自动降级。

### far

- 默认无解码和上传需求；
- 可保留已接近完成的下载连接。

## 6. 状态机

### 6.1 DownloadSession

```text
idle -> queued -> receiving -> sealed -> promoted
          |          |          |
          v          v          v
        failed     failed      failed
```

关键约束：

- append 必须满足 offset == committedLength；
- stale writer chunk 被拒绝；
- 普通 detach 不自动中断 receiving；
- 明确 clear/evict 才触发物理清理；
- cache hit 直接 restore/seal，不伪造下载进度。

### 6.2 DecodeSession

```text
idle -> waitingSource -> queued -> decoding -> ready
                    |         |         |
                    v         v         v
                  failed    stalled   disposed
```

- cursor 只属于一个 DecodeId 和 epoch；
- 同一 decoder 不并发推进两个 cursor；
- source 可解码字节不足时进入 waitingSource；
- demand 为 0 时停止推进，但不必立即销毁。

### 6.3 ReaderTransition

```text
idle -> dragging -> overlap -> dominant -> settling -> idle
          |                         |
          +------ cancel ----------+
```

- only PageView 可基于连续 coverage 提前 dominant；
- 无离散 PageMetrics 的 custom slider 在滚动期间保持 present freeze；
- ScrollEnd、跳页 Future、sentinel 回跳、章节切换和 detach 都必须显式收口。

## 7. 调度和并发

### 7.1 Scheduler Lane

- NetLane
- DecodeLane
- UploadLane
- MaintenanceLane
- PolicyLane

每个 lane：

- 独立优先队列；
- 独立并发上限；
- 支持 task coalescing；
- 支持 stale revision cancellation；
- 任务不在 UI build/layout/raster 同步执行。

### 7.2 默认并发策略

根据设备等级配置，初始中档设备默认：

- network：3
- decode：2，其中 1 个 current reserve
- upload：1 串行提交
- maintenance：1
- policy update：1

当 current frame depth 低于水位：

- near decode 降为首帧或 0；
- current reserve 不可借出；
- transition 只保留首帧需求，直到 current 恢复。

## 8. 下载与 Artifact

### 8.1 文件布局

```text
cache/
  partial/<token>.part
  final/<token>.bin
  db/cache.sqlite
  models/policy_model.bin
  traces/
```

### 8.2 Artifact 元数据

- identity hash
- canonical URI
- committed length
- expected length
- ETag/Last-Modified
- checksum
- content kind
- created/last access
- partial/final path
- source revision

### 8.3 内容嗅探

最小签名前缀判断：

- RIFF....WEBP
- GIF87a/GIF89a
- JPEG/PNG/AVIF 等静态格式
- unknown/fallback

来源历史只用于路由提示，逐文件嗅探仍是权威。

## 9. Animated WebP

### 9.1 Native Source

Rust source 接收连续 chunk：

```rust
append(source, epoch, offset, bytes)
```

必须验证：

- epoch；
- offset；
- source 状态；
- 最大长度和内存限制。

### 9.2 Cursor

Cursor 维护：

- 当前动画帧索引；
- 帧组合状态；
- repetition；
- 可用字节水位；
- decode target；
- source epoch。

### 9.3 Frame Holder

FrameHolder：

- 只保留 policy 指定深度；
- 每帧有 decode claim、upload claim 和 present reference；
- 超出水位时按安全顺序释放；
- frame address 不经过 MethodChannel 复制。

### 9.4 Present

- overlap 阶段可冻结提交；
- holder 可继续准备到水位；
- 未 present 帧不提前消耗播放时长；
- dominant 后由 revision wake 恢复；
- Android 成功提交 texture 后显式 schedule frame。

## 10. GIF

### 10.1 初始实现

- 共用 DownloadSession 和 Artifact；
- 增量索引完整 frame 和安全 completeOffset；
- 仅 current 页持续重建和 pump；
- rebuild 受 minNewFrames、minNewBytes 和 minInterval 节流；
- 下载封口后使用最终 codec。

### 10.2 升级条件

当基准证明 external snapshot 对目标文件产生不可接受的累计解析成本时，实现 Rust native GIF cursor。只替换 Format Runtime，不修改 transport、artifact、identity、policy 或 Reader。

## 11. 缓存架构

### 11.1 两个缓存平面与一个协调入口

`ResourceCacheCoordinator` 是应用装配和缓存管理命令的唯一入口，但不把所有物理资源改成一个所有者。
它协调两个已有边界清晰的平面：

1. **Source response plane**（`resource_cache`）：显式封面/来源图片响应、漫画详情、章节元数据、搜索结果；共享全局与分类型预算、TTL、并发请求合并、LRU 和来源复合失效命名空间。只有完整 `imageBytes` 可通过注入的 `ResourceCacheByteStore` 持久化，章节页面 URI 不属于该平面。
2. **Media pipeline plane**：
   - Disk Artifact Cache：每个页面独立的 partial/final 编码字节；
   - Encoded Memory Cache：由 pipeline/session 按 demand 保留的压缩字节或 mmap view；
   - Decoded Frame Cache：静态图或动画帧；
   - Renderer Texture Cache：可见和 transition 页面。

不完整章节不是一个全有或全无的“章节缓存”：它由可复用的章节元数据与任意子集的页面 partial/final artifact 组成。
`ResourceCacheCoordinator` 分别统计进程内响应、持久响应字节和页面 artifact。持久响应通过可选
`ResourceCacheByteStoreMaintenance` 执行 LRU 整理；页面只能通过
`ArtifactCacheMaintenance -> CacheOps -> DownloadRegistry/DownloadSession` 请求统计和安全驱逐，协调器不能直接删除页面文件或取代 pipeline demand。

### 11.2 设备预算

预算由 `ResourceBudgetResolver` 根据内存等级、热状态、前后台和页面尺寸生成。

默认示例：

| 等级 | Encoded | Decoded CPU | GPU/Texture |
|---|---:|---:|---:|
| low | 48 MiB | 96 MiB | 96 MiB |
| mid | 96 MiB | 192 MiB | 192 MiB |
| high | 192 MiB | 384 MiB | 384 MiB |

系统内存警告可立即降低预算，但仍通过安全驱逐执行。

### 11.3 容量与安全清理

- `CachePolicy` 只根据容量、LRU 和 protected key 生成候选，不删除文件；
- `CacheOps` 负责 trim/clear 编排；
- 最终物理删除必须通过 `DownloadRegistry` 和 `DownloadSession.evict`；
- active run/writer 或调用方保护的资源不能被驱逐；
- 返回实际释放字节，而不是按索引估算成功。

## 11.4 Reader 布局自适应与连续呈现

Reader layout adaptation is a presentation choice, not the resource policy in section 12. `ReaderSessionSettings` resolves in this order: explicit per-comic direction, high-confidence adaptive result, then stored progress/source direction. The classifier may inspect animation hints and page dimensions already present in `ChapterManifest`; it does not sniff bytes, create decode work, or emit `DemandPlan`.

Vertical mode uses a proportional continuous list. Each child keeps the page asset key, download identity and media host. `verticalStitch` only removes the separator. RTL changes PageView/slider visual direction and labels while the underlying page index remains unchanged.

## 12. 自适应策略

### 12.1 决策边界

模型选择有限 `DemandProfile`，不输出直接资源命令。

```dart
enum DemandProfile {
  conservative,
  balancedForward,
  aggressiveForward,
  reversalAware,
  animationCurrentHeavy,
  transitionReady,
  thermalLimited,
  memoryLimited,
}
```

### 12.2 Observation

- 阅读方向和反向率；
- current/stable index；
- viewport coverage 和 gesture velocity；
- 页面停留时间；
- 文件大小、格式、尺寸、帧数估计；
- committed length、throughput、RTT；
- queue delay、frame depth、texture ready；
- 内存、热、电量、计费网络；
- build/raster 和 present gap。

### 12.3 PolicyGuard

硬约束：

- current 最低 download/decode/upload demand；
- 最大窗口和 frame depth；
- scheduler 并发上限；
- 计费网络限制；
- 高温和低内存强制保守策略；
- external GIF rebuild 节流；
- 模型异常回退 heuristic。

### 12.4 学习路径

1. Heuristic only。
2. Profile 化。
3. Shadow model。
4. LinUCB/Linear Thompson Sampling。
5. 小型 MLP ranker。
6. 只有长期依赖被数据证明后再评估 RL。

## 13. Telemetry 和归因

### 13.1 Decision Identity

每次策略决策生成：

- decisionId
- policyRevision
- content/download/decode identity
- sourceEpoch
- selected profile
- action probability
- feature schema version

### 13.2 关键事件

- transitionStarted
- pageDominant
- pageCurrent
- firstFrameReady
- firstFramePresented
- frameDepthChanged
- downloadStarted/sealed/promoted
- demandDetached
- safeEvicted
- staleWorkRejected
- memoryPressure
- thermalStateChanged

### 13.3 奖励

奖励综合：

- visible latency；
- playback continuity；
- useful prefetch；
- wasted bytes；
- decoded but never presented frames；
- stale epoch work；
- current starvation；
- memory/thermal/network cost；
- raster jank。

## 14. 故障恢复

### 网络

- range 可用时从 committed length 恢复；
- range 不可用时保留 receiving，避免频繁重下；
- ETag 改变则创建新 source revision 和 epoch。

### Artifact

- 启动扫描 partial；
- 校验 DB 路径与文件；
- active session 文件不作为 orphan 删除；
- checksum 失败则隔离并重建。

### Native

- decoder panic/错误转为结构化错误；
- 当前页回退到 full-file Flutter/static decode 或错误占位；
- native crash 信息进入本地诊断，不上传原始漫画内容。

### Policy

- 模型 NaN、版本不兼容、文件损坏或异常输出立即回退 heuristic；
- 模型更新采用双文件原子替换；
- 支持禁用个性化。

## 15. 安全与隐私

- 默认不上传阅读页面、图片字节、文件名或完整 URL。
- 端侧模型只保存聚合特征和参数。
- 远程 telemetry 必须显式开关并脱敏。
- 缓存数据库和模型文件不包含认证 token。
- 远程 source 凭据通过平台安全存储。
- 日志对 URI query、cookie、authorization 和本地路径脱敏。


### Local-media import boundary

`apps/app` 不拥有目录枚举或文件头读取。`packages/local_media` 提供本地图片
模型、格式嗅探、桌面 `dart:io` 扫描和平台 facade；
`packages/local_media_bridge` 只实现 Android SAF document tree 与 content URI
读取。App 中的 `local_image_folder.dart` 仅为兼容导出。Android 文件头探测
失败时，MIME/文件名图片候选不会被提前丢弃，最终有效性由打开页面时的
完整 parser/codec 判定。

## 3.9 Android library application shell

The Android-first application shell has three primary destinations: Home,
Bookshelf and Comic Sources. Home derives update cards from catalog update/import timestamps and
history cards from persisted `ReadingProgress`. Bookshelf derives all views from
persisted chapter records plus `ComicPreference`; source/category filters and
sort modes do not create parallel copies of catalog data.

`ImportedLibraryStore` schema version 6 owns source-aware `SavedComicRecord` plus `LibraryCategory`,
`ComicPreference` and `ChapterReadState`. Imported chapters, progress, preferences and read state all
use source-composite durable identities. Preferences include shelf membership, liked/collected flags,
category membership, source kind and custom order. Read state is intentionally distinct from precise
Reader progress so restoring a chapter to unread does not erase the last page.

Cover widgets only receive byte-loader and progress value objects. Animated
thumbnail decoding uses Flutter `Image.memory`; download waterline presentation
does not own a DownloadSession. Reader navigation continues through the existing
promoted-artifact path.


## 3.10 Bookshelf management and Reader interaction shell

Home and Bookshelf both consume catalog-owned `LibraryComic` projections and the same
`ComicCoverCard`; view geometry is presentation policy, not a second library model. Sort mode and
view mode are independent. Management selection is transient App state, while custom order,
category membership and deletion persist through `ImportedLibraryStore`. Drag widgets emit reorder
commands only; they do not mutate catalog lists in place.

Reader app controls are an overlay around `ReaderView`. Page slider, direction and rotation call
`ReaderController`; favorite delegates to an application callback; chapter cache delegates to an
external callback or the existing DownloadRegistry. `ReaderPlaybackController` is a small
ValueNotifier passed through `ReaderPageRuntime` to animated renderers. It does not own encoded
bytes, decode sessions, frames or textures.

Zoom is owned by each page through `InteractiveViewer`. The parent only receives a boolean zoom
state to suspend PageView physics. Page and zoom hosts keep the stable asset identity while the current
role changes; `didUpdateWidget` resets a stale transform in place instead of remounting the media child.
Rotation wraps the page presentation and leaves all content/download identities unchanged.


## 3.11 Remote comic source browser

`BrowsableComicSource` is a catalog boundary, not a Widget plugin. It extends `ComicSource` with a
paged/searchable discovery method, a descriptor and resource loading for source-browser artwork.
The App receives source instances through composition, derives the enabled/order list from
`ComicSourcePreference`, and presents them in the third primary destination. The top app bar opens
management; a bottom strip switches only among enabled sources.

`MangaDexSource` is the first implementation. Browse/detail/feed requests produce `Comic`,
`Chapter` and `ChapterManifest` values. Whole-comic preference actions persist `SavedComicRecord`;
opening or downloading one chapter converts only that chapter manifest to `ImportedChapterRecord`.
No source creates Reader controllers, DownloadSessions or artifacts. Source-browser cover requests
use `loadResource`, while chapter pages are downloaded by the existing Reader transport and
promoted-artifact path. For source-owned opaque locators such as `mihon:` and `venera-resource:`,
`downloads` selects a `LoaderTransport` through an injected source-resource loader. App composition
only resolves the active `BrowsableComicSource`; UI code does not branch on schemes or own bytes. Newly generated Venera page locators are constrained, versioned and self-describing so they survive runtime generation changes; legacy in-memory tokens are read-only compatibility. Locator payloads may preserve image/comic/episode identity but cannot embed arbitrary final request headers, methods or scripts.

Remote delivery URLs are mutable and may legitimately repeat inside one chapter. `ImportedPageRecord.pageId`
stores the source-provided stable page identity separately from `sourceId`/URI and is the only per-chapter
uniqueness requirement. A remote chapter resolves a fresh manifest before opening,
and store reconciliation follows `stablePageId`; a unique display-name fallback only supports
records written before page IDs existed. SQLite schema version 3 added `comic_source_preference`;
version 4 added source-composite `saved_comic`; version 5 makes imported chapter, progress, comic
preference and read-state ownership source-composite as well.

This contract is intentionally smaller than an external extension runtime. `external_plugin_catalog.dart`
parses Mihon extension repository metadata and Venera JavaScript source indexes into format-neutral,
untrusted catalog entries. Mihon accepts the current `extensionList.extensions` v2 object and the legacy
flat array. Venera accepts both `filename` and deployed `fileName`, preserving a declared `key` immediately
and deferring discovery only when absent. Catalog parsing preserves native package/source identities but
downloads or executes nothing.

`packages/plugin_host` is the pre-execution and runtime-adaptation boundary. A
`PermissionedExternalComicPluginHost` separates immutable-payload inspection from ecosystem-specific execution,
applies repository/payload/package/signer/version/ABI/capability policy, quarantines failed activations and
validates runtime source identities. `ExternalPluginRuntimeRegistry` owns active sessions and prevents source-ID
collisions. Android metadata inspection resolves normalized Mihon entry classes without loading them.

After approval, Mihon and Venera backends activate an `ExternalPluginRuntimeConnection`. Both ecosystems use one
versioned wire protocol for source descriptors, browse, comic detail, chapter manifest and binary resource calls.
`ExternalPluginRuntimeSession` is the sole adapter from that protocol to ordinary namespaced
`BrowsableComicSource` instances. It revalidates request IDs, payload shape, content identities, timeout, response
bytes and actual in-flight concurrency. A timed-out caller stops waiting, but its permit remains held until the
isolated operation really exits. Closing first signals the isolated connection, rejects queued calls and then
drains real work. Reader, navigation, demand, `DownloadSession`, cache-maintenance and artifact APIs never cross
this boundary.

Before reaching `ExternalPluginRuntimeSession`, an isolated backend is wrapped by `ExternalPluginRuntimeMessageChannel`. A schema-versioned handshake carries a non-empty runtime identity and unique source descriptors. Every invocation serializes protocol-v1 values across the raw channel, reparses the response and verifies its request ID; only primitives, maps/lists and bounded `Uint8List` cross. The channel close is joinable and rejects new sends once teardown begins.

Inside the isolated boundary, both ecosystems use `ExternalPluginRuntimeWorker` as the server-side protocol owner. The worker reparses the raw request, verifies that the advertised source is active, rejects duplicate in-flight request identities, sanitizes driver failures and tracks the real driver Future until exit. Ecosystem drivers receive only a protocol request plus a cooperative cancellation token.

A caller timeout may send request-level cancellation through `CancellableExternalPluginRuntimeMessageChannel`, but cancellation is advisory. The host invocation gate retains its permit until the original channel Future completes, so a non-cooperative APK or script cannot exceed the declared concurrency limit by timing out. Worker/session close is joinable, stops admission, signals cancellation/driver close and drains actual work.

Android host adapters serialize the exact inspected execution envelope and limits for Mihon and Venera, then expose invoke/cancel/close through one platform channel. The dedicated `:zic_plugin_runtime` service registers process-local Mihon and Venera drivers; unsupported ABI/capability paths fail closed. Loading in the application process is not an allowed fallback.

At isolated-process entry, `ExternalPluginRuntimeActivationEnvelope` reparses the raw activation map with exact fields and format-specific identity. `FileExternalPluginRuntimePayloadVerifier` does not hand the original host path to a driver: it streams the approved bytes into a process-private partial file while recomputing SHA-256, atomically promotes the verified copy, and keeps that copy alive for exactly one process session. `ExternalPluginRuntimeProcessHost` owns the session registry and routes invoke/cancel/close to the shared worker. A new process starts with an empty registry, so interrupted requests are never replayed automatically after service death.
Sessions remain charged to the process limit until their driver really closes. If process shutdown begins while payload verification or driver creation is in flight, activation is rejected and its private staged payload is drained instead of publishing a doomed session.

Concrete APK class loading and JavaScript evaluation remain separate isolated backend implementations inside
the dedicated process. Mihon uses a verified private APK copy and Venera uses a restricted UI-less WebView. Both
reuse the exact inspected payload and cannot bypass trust, capability, resource-limit or session teardown gates.
Mihon host dependencies use one provider per binary namespace. The pinned `extensions-lib` AAR is loaded into the App only as a non-transitive ABI artifact; the current Keiyoushi common bundle supplies Injekt, coroutines, serialization, networking and parser libraries. Because dynamically loaded APK bytecode is absent from R8's static graph, the bridge publishes consumer keep rules for the host ABI and common runtime. Activation checks the core Source/model, Preference and Injekt classes before constructing the extension class loader and fails explicitly when the release package is incomplete.

## 3.12 Generated host network capability

The repository does not make generated Flutter Android/iOS directories architectural authorities.
After host generation, `tool/configure_platforms.py` applies the small product-owned Android overlay
by ensuring the main manifest declares `android.permission.INTERNET`. Bootstrap, build and run scripts
invoke the same idempotent operation. Generated host files remain disposable, while the required
capability is reviewable and reproducible from repository source.

This host preparation is separate from `Transport`. `HttpTransport` continues to own request/response
semantics, range validators and socket failures. Source presentation receives structured failures and
may format/copy diagnostics, but it does not resolve DNS, open sockets or alter TLS policy.

## 3.13 Detail ownership, durable comic records and source migration

`RemoteComicDetailsScreen` and `LocalComicDetailsScreen` compose shared presentation widgets but own
different state. `resolveComicDetailsRoute` is the only source-card routing decision and checks exact
`sourceId + comicId` durability. `SavedComicRecord` lets whole-comic preference actions retain metadata
and a source chapter catalog independently of imported chapters.

`PersistentChapterDownloadService` owns the durable offline root and index. It reuses the existing
transport/download session machinery, promotes every page, verifies chapter completeness and exposes
page-byte reads after restart. Reader may consume those bytes, but details Widgets only submit commands
and display status.

Cross-source migration creates a target comic copy rather than mutating source identity. Exact
normalized-title plus sequence matches can rehydrate target chapter metadata and copy bounded progress
and read state. Source URLs, caches and original records are never transferred or deleted. Schema version 6 retains
all preference/chapter/progress/read keys as source-composite, so an equal native ID under another source
is a distinct durable record rather than a migration conflict.

## 3.14 Library migration diagnostics

`library_migration_issue` is an audit table, not a queue that owns library mutation. Schema version 6
adds an optional acknowledgement timestamp. Store queries can project pending records or all retained
records; acknowledgement only changes that timestamp. The UI may copy, filter or acknowledge the
records, but it must not delete source-ambiguous rows or reinterpret the migration decision.

`LibraryDiagnosticsScreen` depends only on `ImportedLibraryStore`. It does not inspect SQLite directly
and it does not become a second migration engine. This keeps schema upgrade decisions in storage while
the App owns discoverability and presentation.


## 3.15 Durable whole-comic scheduling

`WholeComicDownloadQueue` is an application scheduler, not a byte owner. It persists the comic identity,
chapter catalog, completed chapter identities and policy, then delegates every chapter to the existing
`ChapterDownloadService`:

```text
WholeComicDownloadQueue
        | schedule / pause / resume / policy
        v
ChapterDownloadService
        v
DownloadRegistry -> DownloadSession -> Artifact
```

The queue may run a configurable number of chapters concurrently. On restart, an in-flight queue phase is
normalized to queued work and each chapter is inspected before scheduling. Pausing, cancellation and a policy
transition call the chapter service rather than deleting partial artifacts directly.

`runtime_bridge` only supplies versioned environment signals: validated network availability, Android metered
state and charging state. It has no transport, artifact or queue mutation authority. Platform-channel failure
keeps the last trusted environment snapshot; unsupported hosts use an explicit injectable fallback.
## 9. 跨漫画源迁移证据边界

跨源迁移分为三个明确阶段：

1. 目标源搜索和目标 manifest 加载；
2. 只读比较与用户确认；
3. 逐章节目标身份验证后才开始持久写入。

`ComicSourceMigrationPlan` 继续拥有保守章节匹配和偏好合并规则。`ComicSourceMigrationComparison` 只从该
计划派生展示证据：来源复合身份、标题/作者重合、阅读方向、精确/仅序号匹配、未匹配数量和有限章节样本。
它不能访问 Store，也不能执行迁移。UI 仅负责加载两侧封面并展示证据；勾选确认不会重新加载封面。

只有精确匹配章节会进入后续阅读位置与已读状态迁移。仅序号匹配只作为风险证据展示，不会因用户确认而
自动升级为可迁移状态。目标源已有偏好和阅读状态继续优先保留，来源 URL、离线 artifact 和原来源记录不复制、不删除。

## 12. App composition, unified response cache and Reader ownership

The Home shell remains divided by ownership rather than by arbitrary file size:

```text
DemoHome                      navigation / dialogs / use cases
  -> HomeLibrarySession       durable library projection + subscriptions
  -> demo_home_views.dart     Home and Bookshelf composition
  -> home_widgets.dart        reusable cover/shelf/action presentation
```

These files are Presentation/Application composition only. They may request a resource through an injected interface,
but they do not define cache policy, prefetch windows, download state machines or artifact lifetime.

Reusable source responses share one package-level manager:

```text
Catalog UI / details / search
        v
CachedBrowsableComicSource
        v
ResourceCacheManager
  - imageBytes -> optional durable ResourceCacheByteStore
  - comicDetails
  - chapterMetadata
  - searchResults
  - global + per-kind budgets
  - TTL + in-flight coalescing + LRU
  - source/comic namespace invalidation
```

A cache namespace groups cover, detail and chapter-metadata responses for one exact `sourceId + comicId`. Explicit
refresh invalidates that namespace or the source search namespace. Clear/refresh increments cache generations, so a
request started before invalidation may still return to its original caller but cannot repopulate the cache afterward.
The manager stores encoded response values only; it never owns decoded frames or textures. Complete
`imageBytes` may be written to a bounded file store using the full key, expiry and content verification.
The standard image TTL is seven days. Successful loads await that write, and cache close drains active
loads plus queued persistence before closing the store. A source revision distinguishes changed cover
content while explicit namespace refresh removes both memory and durable records. Production path composition is
centralized by `storage_bridge.createAppResourceCache`; UI Widgets receive the coordinator and never derive durable
paths or instantiate a second response manager. A two-start integration fixture uses this same factory and a real file
store to prove both source-card and detail-cover reuse.

Chapter page bytes are intentionally excluded from `ResourceCacheKind`. `BrowsableComicSource.loadResource` remains a
raw transport entry for Reader/download work:

```text
ReaderView -> ReaderObs -> ReaderBinding -> PipelineController
           -> DemandPlan -> LiveCoordinator
           -> DownloadSession -> partial/final page Artifact
           -> DecodeSession -> FrameHolder -> Texture
```

The trace schema correlates `pageTransition`, `artifactSource`, `decodeDemand/decodeStarted`,
`uploadDemand/uploadStarted`, `firstFrameReady` and page-host lifecycle events by stable identity and demand revision.
Queued work keeps the revision that created its demand rather than reading a later global revision at execution time.
This instrumentation observes ownership; it does not choose a window, retain a frame or start extra work.

Presentation must not warm current/next/previous pages directly, retain adjacent `PageView` children as a resource
policy, or create a private page-byte LRU. Page and zoom hosts use stable asset keys; a current-role change resets
page-local zoom through an ordinary Widget update without remounting the loaded media child. Byte, decode and texture
reuse is still determined by demand/session/media identities rather than Presentation cache policy.

A Reader session still downloads into an isolated ephemeral workspace. `PromotedArtifactCacheHandoff` in `downloads`
observes sessions created by that registry and submits only final `promoted` bytes to `ArtifactCacheStore` before the
workspace is removed. A later session composes `ArtifactCacheTransport` ahead of its normal source transport: an exact
`DownloadId` hit is copied through the same `DownloadJob/DownloadSession` state machine into the new session artifact;
a miss, validator mismatch or ambiguous duplicate URI delegates unchanged to the transport chosen by
`LiveCoordinator`. The handoff has no demand, rank, prefetch or eviction authority.

Offline content is not a whole-chapter cache object. Chapter metadata is a catalog response; every downloaded page image is
an independent partial/final artifact with its own busy and eviction state. Therefore an incomplete chapter is naturally
represented as chapter metadata plus any subset of promoted or partial page artifacts. The memory fallback follows the
same page-granular contract and does not reload retained pages after cancellation. `ArtifactCacheMaintenance` submits
inspect/trim/clear through the existing index and `CacheOps`. A single
`ResourceCacheCoordinator` exposes the response plane and coordinates artifact maintenance without taking physical
ownership. Its maintenance policy owns response/artifact thresholds; App code receives the coordinator unchanged, does not
assemble cache budgets ad hoc inside a page, and does not construct response-cache keys.

`downloads` owns `ChapterDownloadService`, the persistent page-artifact implementation and
`WholeComicDownloadQueue`. It also owns transport selection for a page: normal file/http(s) locators use the ordinary
I/O transport, while source-owned opaque locators use an injected `ChapterResourceLoader` and still pass through the
same `DownloadJob/DownloadSession` artifact lifecycle. `downloads_bridge` adapts runtime network/power signals and
JSON persistence. Download Manager is a presentation/command surface over those interfaces; it cannot open the index,
delete files directly, select a transport or mutate library metadata.


Reader transition replay is owned by `telemetry`, while exact page/DownloadId identity construction is owned by
`downloads`. Replay separates transition revision from the frame-producing work revision and is observational only.


## External plugin dedicated-service ownership

The Android host bridge and the dedicated runtime service share `ExternalPluginRuntimeServiceMethods`, but the platform transport owns no plugin session policy. A service-side `AndroidExternalPluginRuntimeServiceHandler` forwards raw method calls into `ExternalPluginRuntimeServiceEndpoint`, which delegates to `ExternalPluginRuntimeProcessHost` for activation parsing, immutable payload staging, driver creation, request routing, cancellation and deterministic shutdown.

Every service process has a new `processId`. Activation returns `{processId, sessionId, handshake}` and every later invoke/cancel/close carries both identities. After service death or restart, a stale process generation is rejected before session lookup even if a session identifier is reused; failed operations are never transparently replayed or reactivated.

The main-process Binder client separately assigns a binding generation to each explicit Android bind and installs an `IBinder.DeathRecipient`. Service loss retires only that generation, fails its pending/queued calls once, unlinks/unbinds it and leaves reactivation to a later explicit caller. A delayed callback from a retired generation cannot tear down a newer connection. If every caller times out before binding completes, the idle binding is abandoned so the next explicit activation can retry.

Large response packets carry an exact byte length and SHA-256 in the Binder envelope. The host accepts only canonical `.packet` files below the dedicated app-private root, verifies length and digest during the single file-to-platform-buffer read, and deletes the file on success or validation failure. Inline response envelopes use the same digest contract.

Generated Flutter Android hosts must add canonical JitPack to the repository owner that resolves App runtime classpaths. `tool/configure_platforms.py` patches centralized `dependencyResolutionManagement.repositories` when present, otherwise the generated root `allprojects.repositories`; a plugin-local repository declaration is not treated as sufficient for `:app:*RuntimeClasspath`.
Repository visibility does not authorize duplicate providers. `extensions-lib` legacy transitive metadata is disabled, AndroidX Preference is not declared a second time, and the current null2264 Injekt fork is the only Injekt runtime. The repository gate checks this topology before toolchain work; Android's own duplicate-class task remains enabled as the final artifact-level verifier.

Persistent external-plugin restoration is path-confined. A manifest record is eligible only when its payload is a regular non-link file, has the ecosystem suffix, and resolves below the controller-owned `external_plugins` root. Mihon runtime extraction then uses a workspace keyed by plugin, version and activation `driverId`; activation failure or drained close removes that workspace, while dedicated-Service startup removes roots left by process death.
## Venera locator generation and measured Reader geometry (dev.66)

Venera chapter metadata is versioned independently from page artifacts. A durable `venera-resource:<payload>` locator carries only the original image identity and comic/episode identity; the active runtime source reconstructs the network configuration. Persisted `venera-resource://token` values are generation-scoped and cannot be reconstructed after runtime loss, so chapter metadata cache revision and App compatibility loading force a fresh source chapter before Reader or download use.

Within one runtime, resolved `onImageLoad` configurations are bounded and keyed by locator. Concurrent resolution shares one Future/Promise. The Dart source adapter also shares one in-flight invocation for identical URIs, then removes it at completion. Neither layer becomes a long-term page-byte owner; Reader/download sessions and artifacts remain authoritative.

Continuous Reader geometry follows this order: source-declared dimensions, runtime-observed dimensions from the already-owned media payload, then a short conservative placeholder. Static PNG/JPEG/GIF/BMP/ICO dimensions are parsed from the same bytes used for decode; WebP uses the existing container parser. The implementation must not resolve a second ImageStream or crop content to hide geometry errors.

Reader navigation commands are transactional with presentation readiness: after a direction/layout change, the target ScrollPosition must be attached and report content dimensions before jump and acknowledgement. A command that has not reached the target container remains pending rather than appearing successful.

## Reader control ownership and narrow header projection (dev.67)

Reader navigation has one Presentation command surface. Horizontal/RTL/continuous gestures and the bottom Slider issue `ReaderController.requestPage`; no source-specific screen or top-bar extension receives the controller. Layout direction, adaptive mode and stitch behavior enter through `ReaderSessionSettings` from global or per-comic preferences.

```text
Global/per-comic settings ----> ReaderSessionSettings ----> ReaderController.setDirection
Reader gesture / bottom Slider ---------------------------> ReaderController.requestPage
Top bar --------------------------------------------------> title/subtitle/progress only
```

`ReaderRuntimeScreen` no longer accepts arbitrary title or action Widgets. A caller may provide only `pageSubtitleBuilder(PageAsset) -> String`; runtime owns the title layout and semantics. This prevents local-media or future source adapters from recreating page counters, previous/next buttons, selection menus or alternate navigation state in the top bar.

Session settings and adaptive classification live in `reader_session_settings.dart`, separate from runtime composition and control rendering. The runtime screen has a 1500-line repository budget. Vertical navigation acknowledgement is observation-backed: the command remains pending until the target lazy page has been laid out, the scroll position resolves to that page and the Reader observation is published.


## Venera entry preflight and continuous-page seams (dev.68)

Locator migration is enforced at command composition, before Reader or download work exists. The App asks the source's optional `RefreshableChapterComicSource` capability for fresh metadata whenever a persisted chapter contains a generation-scoped Venera token. The source-resource loader and runtime adapter are defensive sinks that reject the same token before plugin invocation; they do not own chapter migration or page caching.

```text
Persisted chapter --legacy token--> refresh chapter metadata --durable locator--> Reader/download
                                      | still legacy
                                      +-------------------------------> fail before demand
```

Deferred Venera locators require source JavaScript and native HTTP resolution, so their policy window is composed explicitly at `ReaderBinding`: current plus one forward encoded page, guarded to at most two downloads. Their `LiveCoordinator` uses a single-attempt retry policy; ordinary chapters keep the default role window and retry policy. In-flight URI coalescing remains below this policy and does not retain completed bytes.

Stitched continuous presentation uses adjacent sliver children with no separator object. Page extent comes from source geometry, then measured geometry from the already-owned media payload, then a viewport-sized active placeholder. In stitched mode the media renderer receives `BoxFit.fitWidth`, including Flutter images, animated codecs and native textures, so a contain-style rounding margin cannot reopen a visible seam. The parent extent still comes from the same source/measured geometry, so this width fit does not authorize cropping or stretching. The placeholder is presentation state only; it never changes page identity, download identity, decode ownership or cache keys.


## Venera binary transport and continuous anchor ownership (dev.69)

- Durable `venera-resource:` identifies how to reconstruct source configuration; it is not the image byte transport. Ordinary image bytes use `http_binary`: the WebView receives only status, headers and an opaque native token, while the verified runtime packet carries the `Uint8List` back to Dart. `onResponse` and `modifyImage` explicitly opt into the legacy JS-byte compatibility path.
- Runtime `requestId` is propagated by the sandbox bridge to every native HTTP call. `VeneraNativeBridge` tracks request-scoped URLConnection/fallback calls; cancellation disconnects them immediately, and JS `finally` releases scoped cancellation state.
- Venera resource work is serialized and the Reader role resolver exposes only the current page. `PipelineController` does not publish a new plan when the role map is unchanged.
- Continuous layout owns presentation geometry only. Source dimensions or the already-owned media bytes update `pageAspectRatios`; Reader records the viewport-center page and in-page fraction before reflow and restores that anchor after layout. It never restores while the scroll position is active.
- Stitched preference is tri-state at per-comic scope. `null` inherits the global value; `true` and `false` explicitly override. Stitched layout creates no separator and overlaps adjacent painted pages by one logical pixel to cover device-pixel rounding without cropping source pixels.
- Loading indication belongs to the Reader viewport. Page media widgets report first frame and dimensions but do not draw a competing spinner inside continuous page boxes.
