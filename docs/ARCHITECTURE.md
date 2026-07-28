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

## 2. 仓库结构

```text
zic/
  apps/
    app/                     Flutter 应用入口

  packages/
    domain/                  领域实体、identity、值对象
    catalog/                 书架、章节、来源抽象
    reader/                  Reader UI、viewport、交互报告
    pipeline/                policy/window/ranker/demand
    sessions/                download/decode/display session
    transport/               网络、本地文件、resume
    storage/                 artifact、cache index、SQLite 与持久目录库
    storage_bridge/          Flutter 应用支持目录与 storage 后端装配
    telemetry/               指标、事件、trace、设备状态
    bridge/                  FFI、native source/cursor/frame handle
    texture_bridge/          Flutter texture 契约与 Android 插件
    local_media/             本地图片模型、格式嗅探、桌面目录枚举和平台 facade
    local_media_bridge/      Android SAF document tree/content URI 插件
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
fallback 写入同一 monotonic trace。`ReaderBinding.revision` 是输出层只读的
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

`catalog/LibraryComic` 是这些章节快照上的只读漫画级投影：它按 `comicId` 聚合章节，
解析 cover/latest/resume chapter、总页数与更新时间，供 Home、Bookshelf 和详情页共享。
聚合不写数据库、不接管 Reader/DownloadSession，也不隐藏 chapter identity；目录刷新、
阅读进度、read state 和删除级联仍由原 store/session 契约负责。

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

### 11.1 层级

1. Disk Artifact Cache：partial/final 编码字节。
2. Encoded Memory Cache：章节附近压缩字节或 mmap view。
3. Decoded Frame Cache：静态图或动画帧。
4. Renderer Texture Cache：可见和 transition 页面。

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

The Android-first application shell has two primary destinations: Home and
Bookshelf. Home derives update cards from catalog update/import timestamps and
history cards from persisted `ReadingProgress`. Bookshelf derives all views from
persisted chapter records plus `ComicPreference`; source/category filters and
sort modes do not create parallel copies of catalog data.

`ImportedLibraryStore` schema version 2 additionally owns `LibraryCategory`,
`ComicPreference` and `ChapterReadState`. Preferences include shelf membership,
liked/collected flags, category membership, source kind and custom order. Read
state is intentionally distinct from precise Reader progress so restoring a
chapter to unread does not erase the last page.

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

Zoom is owned by each current page through `InteractiveViewer`. The parent only receives a boolean
zoom state to suspend PageView physics. Navigation changes the zoom-page identity so stale transforms
cannot reappear with page scrolling re-enabled. Rotation wraps the page presentation and leaves all
content/download identities unchanged.
