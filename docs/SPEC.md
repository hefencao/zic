# zic Product and Engineering Specification

## 1. 版本范围

本文定义 `zic` v1.0 的目标规格，并标出 v0.x 的增量实现顺序。

## 2. 用户能力

### 2.1 书架

用户可以：

- 添加本地文件夹、归档文件或远程章节清单；
- 查看漫画、章节、封面和最后阅读位置；
- 删除书架条目而选择是否保留离线缓存；
- 查看章节下载状态；
- 在画廊或列表视图中使用相同排序方式；
- 在管理模式中选择漫画、移动分类、编辑分类归属和确认删除；
- 在自定义排序中长按拖动封面或重排列表行。

### 2.2 阅读器

支持：

- LTR 分页；
- RTL 分页；
- 纵向连续滚动；
- 单页缩放与拖动；
- 章节前后跳转；
- 当前页、总页数和章节信息；
- 静态 JPEG/PNG/WebP；
- Animated WebP；
- GIF fallback；
- 本地和远程来源；
- 默认沉浸并隐藏控制栏，轻触切换控制栏；
- 页码滑杆、暂停、倍速、旋转、收藏和章节缓存命令。

### 2.3 下载与离线

- 单章下载；
- 后台保留已建立的合法下载任务；
- 可恢复 partial；
- 缓存大小展示和清理；
- active 资源不会被清理操作破坏。

### 2.4 自适应体验

- 用户可启用或关闭“智能预加载”。
- 用户可选择省流量、平衡、性能优先。
- 默认使用确定性策略；积累足够数据后启用端侧个性化。
- 用户可重置模型。



## 2.6 Comic source destination

- The third primary destination displays remote comic sources.
- A top app-bar action opens source management; management persists enabled state and order.
- The bottom source strip switches among enabled sources without duplicating application navigation.
- A source page supports refresh, title search, paging, comic details and chapter actions.
- Saving/opening a source chapter must first create a catalog chapter record; direct source-to-Reader
  byte ownership is forbidden.
- If no source is enabled, the page stays usable and points to the management entry.
- Upstream/network failures are explicit and retryable. The application must not silently add
  cookie theft, challenge solving or anti-bot bypass.

## 4.2 Remote source contract

A remote source exposes stable source/comic/chapter/page identities, discovery summaries, details,
chapter manifests and resource loading. Source enablement/order is durable application preference,
not source-owned state. Source-provided page identity must be persisted independently from current
delivery URI so a refreshed at-home/CDN URL does not move Reader progress. Remote chapter bytes
continue through Reader demand, transport, promoted artifact and decode ownership.


## 3. Reader 行为规格

### 3.1 当前页优先

当页面成为 current：

1. 其 download rank 为最高；
2. 其 decode task 可使用 reserved worker；
3. 其 upload task 优先于 near；
4. near demand 必要时降级；
5. 首帧 ready 后立即可显示，不等待完整动画缓冲。

### 3.2 Transition

分页阅读中：

- gesture 开始后根据方向确定 target；
- target viewport coverage 达到配置阈值前为 candidate；
- 明显 overlap 时 target 升为 transition 并可准备首帧；
- target 成为 dominant 后恢复 present；
- `onPageChanged` 只确认 current，不作为首次资源提升时机。

### 3.3 Cancel/Reversal

- 用户取消手势时，target transition demand 撤销；
- 已 receiving 的下载是否保留由 reconciler 决定；
- 已准备 frame 可短期保留；
- 反向率进入后续策略特征。

### 3.4 Zoom

- 当前页缩放不改变编码 download identity；
- 只有实际物理解码目标变化超过对齐阈值时创建新 DecodeId；
- 临时 pinch 不应连续创建 holder；
- zoom 结束后延迟提交稳定 decode target。

## 4. Source 规格

```dart
abstract interface class ComicSource {
  Future<ComicManifest> loadComic(String comicId);
  Future<ChapterManifest> loadChapter(String chapterId);
  Future<ByteStreamResponse> openPage(PageAsset asset, ByteRange? range);
  Future<SourceValidators> validators(PageAsset asset);
}
```

`ByteStreamResponse` 必须提供：

- stream；
- status；
- content length；
- content range；
- ETag/Last-Modified；
- mime hint；
- canonical URI。

来源不得直接访问 Reader Widget。

### 4.1 Reader artifact ingress（当前 v0.x 契约）

- `ReaderObs` 经 `ReaderBinding` 产生的 download demand 必须交给生产
  `LiveCoordinator`，App 不得用 fake coordinator 代替运行时生命周期。
- manifest 的 source/comic/chapter/page/sourceRevision/canonical URI 共同生成
  `DownloadId`；显示层不得为同一页面重新发明另一套下载身份。
- Reader 媒体字节只从 promoted artifact 读取。asset bundle、file 和 http(s) 可以
  使用不同 transport，但必须经过同一 DownloadJob/DownloadSession 状态机。
- Reader session 的 final artifact 只有在 `DownloadState.promoted` 后才可提交到持久页面缓存；退出前必须
  drain 已开始的提交，再删除临时 workspace。新 session 的缓存命中仍需重新经过自己的
  DownloadJob/DownloadSession，禁止直接把缓存 bytes 交给播放器。
- cache transport 只接受精确 `DownloadId` 身份。一个 URI 若在同一 manifest 中对应多个页面身份必须绕过
  缓存；range 命中必须验证内容派生 validator，失败时回退到原 source transport。
- viewport target 或 Reader session 被替换时，旧 binding 必须先 reconcile 到 empty；
  旧异步结果仍受 epoch、identity 和 cancel token 约束。
- 等待 promotion 使用只读 snapshot observer。observer 失败不得改变下载状态、writer
  lease、artifact 或 lane 调度。
- 本地文件夹必须先形成 `ImportedChapterRecord` 和 `ChapterManifest`；content URI、
  文件路径、source revision 与页顺序共同构成 Reader identity。平台 loader 必须通过
  Transport/DownloadSession 进入 promoted artifact，目录 UI 不得旁路直接读取当前页。
- UI 请求页跳转时只提交有边界校验的 Reader command；PageView 是命令消费者，目录页
  不得维护第二套 authoritative page index。

## 5. 数据模型

### Comic

- comicId
- sourceId
- title
- authors
- coverAsset
- description optional
- readingDirection
- createdAt/updatedAt

### Chapter

- chapterId
- comicId
- title
- sequence
- pageCount
- publishedAt
- sourceRevision


### LibraryComic projection

- comicId
- comicTitle
- sourceId + comicId identity
- ordered persisted chapter entries
- optional saved source-catalog chapter snapshot
- cover/latest/resume chapter
- aggregate page count
- latest import/activity timestamps

`SavedComicRecord` 可在零持久章节时保存整部漫画元数据与轻量目录快照。远程详情拥有实时
上游目录，本地详情拥有该记录和持久章节；两者复用组件但不共享状态所有权。用户打开章节
时才持久化 Reader manifest，行尾下载才持久化离线 artifact。chapter progress、read state、
download session 和 artifact ownership 仍保持逐章节/逐资源权威。跨源迁移不得仅按标题
自动聚合；必须显式选择目标并重新解析目标源 manifest。

### PageAsset

- pageId
- chapterId
- index
- uri
- width/height optional
- byteLength optional
- contentKind hint
- animated hint
- checksum optional

### ReadingProgress

- comicId
- chapterId
- pageIndex
- subPageOffset
- readerMode
- updatedAt

### CacheRecord

- download identity hash
- partial/final path
- committed/expected length
- validators
- checksum
- state
- lastAccess
- size
- active generation

### PolicyModelRecord

- model kind
- schema version
- parameter version
- sample count
- created/updated
- checksum
- disabled reason optional

## 6. 公共接口契约

### 6.1 ReaderObs

```dart
final class ReaderObs {
  final String sessionId;
  final int currentIndex;
  final int stableIndex;
  final Interaction interaction;
  final double logicalPosition;
  final double velocity;
  final Coverage currentCoverage;
  final Coverage? targetCoverage;
  final ReadingDirection direction;
  final DateTime timestamp;
}
```

### 6.2 DemandPlan

```dart
final class DemandPlan {
  final int revision;
  final Map<DownloadId, DownloadDemand> downloads;
  final Map<DecodeId, DecodeDemand> decodes;
  final Map<DecodeId, UploadDemand> uploads;
  final Set<ResourceId> keep;
}
```

Demand 必须包含：

- role；
- priority；
- target watermark；
- reason；
- expiration revision；
- decisionId optional。

### 6.3 SessionSnapshot

只读快照，不暴露 mutable session：

- state；
- epoch；
- committed length；
- frame depth；
- active lease/claim 数；
- queue latency；
- last error；
- texture readiness。

### 6.4 本地 WebP 选择与预览

选择器返回 `PickedWebp(displayName, file)`：

- `displayName` 由选择边界显式拥有并传给路由；
- `file` 只负责字节访问；
- 用户取消返回 `null`，不得创建预览路由；
- 合法和非法 WebP 必须先经过纯容器校验，再进入具体 renderer；
- 预览页面通过显式状态对象暴露 `loading`、`ready`、`invalid`；
- 错误区域、页面、标题和 renderer 控件使用稳定语义 key；
- 新增辅助文案、状态栏或布局不应破坏业务测试。

目录选择返回 `PickedImageFolder(directoryPath, displayName, files, scannedFiles, unreadableFiles)`：

- 用户取消返回 `null`，不得枚举目录或创建路由；
- 目录枚举递归访问所有普通文件并在 UI isolate 之外执行；
- 类型由文件头签名识别，不依赖扩展名、扩展名大小写或 `XFile.name`；
- 文件头阶段只负责格式嗅探，不把 RIFF 声明长度、首个 WebP chunk 类型或完整 codec 校验混入目录筛选；未知/元数据前置 chunk 不得导致可解码 WebP 漏检；
- 当前识别 PNG、JPEG、GIF、WebP、BMP、TIFF、ICO、AVIF 和 HEIF；
- 扩展名像图片但文件头不匹配的文件必须忽略；无扩展名或错误扩展名的真实图片必须导入；
- Android 若返回不可枚举的 `content://` URI，必须报告路径能力错误，不得转换为空目录提示；
- 每个文件的相对 `displayName` 和 `LocalImageFormat` 由导入边界显式拥有；
- 顺序使用确定性的自然路径排序；
- 切换时只保留一个当前播放器，不得同时启动整个目录的 codec/texture；
- 完全没有可识别图片时才提示空目录，并附带扫描与不可读文件计数；
- 上一项、下一项和文件选择使用稳定语义 key，必须测试真实 source 与格式切换。
- 成功导入后必须持久化可序列化章节记录；重新启动后可从本地目录库重新打开。
- Reader 当前页和 paged/continuous 模式写入 `ReadingProgress`；旧时间戳不得覆盖新进度。
- 目录重新导入导致页数减少时，持久进度必须收敛到新的最后一页。
- 已持久化目录必须可在不重新打开 picker 的情况下刷新；Android 复用 SAF tree URI，桌面复用目录路径。
- 刷新时页面 identity 由 source identity 决定；当前图片仍存在时，新增/删除前置页面不得改变阅读对象。
- PNG 文件头嗅探至少要求完整 signature、IHDR 长度/标签和非零宽高；仅有容器标签的截断数据不得成为图片候选。

所有 WebP 页面默认使用 Flutter codec。Native FFI/texture 只能在用户显式选择
实验 renderer 并确认后启动；取消确认不得创建 source、cursor 或 texture。

### 6.5 Android Texture Present

一次 present 的所有权顺序：

1. 调用者持有原始 `NativeFrame`；
2. Dart presenter retain 临时 owner 并跨 MethodChannel；
3. Kotlin lane 在 blit 前通过 JNI retain 平台 owner；
4. 成功呈现后平台 owner 成为 texture 当前帧；
5. MethodChannel 完成后 Dart 临时 owner release；
6. 下一帧、resize、texture release 或 engine detach release 平台 owner。

平台必须串行执行 blit、resize 和 release。任何失败路径都必须完成调用并释放
临时 owner。`SurfaceProducer` 的 callback、setSize、release 和 scheduleFrame 由
平台主线程拥有；blit lane 只执行 native surface 写入和 frame owner 变更。
已排队的 scheduleFrame 必须同时检查 engine attachment 与 output 存活状态。
engine detach 或 output release 后禁止调用 `scheduleFrame`。Flutter `Texture` 不提供 `BoxFit`，因此 texture 必须先放入以源画布宽高比约束的 contain viewport；decode/display telemetry 数值正确不能替代实际布局比例验证。

present telemetry 至少包含：

- decode/frame index 与 frame bytes；
- queue、upload 和 deadline miss 微秒数；
- texture bytes 与 in-flight bytes；
- fallback reason。

### 6.6 Native FFI

最小 ABI：

```text
zic_source_create
zic_source_append
zic_source_seal
zic_source_reset
zic_cursor_create
zic_cursor_decode_next
zic_cursor_seek_start
zic_frame_retain
zic_frame_release
zic_frame_info
zic_source_dispose
zic_cursor_dispose
zic_last_error
```

约束：

- 所有 handle 为不透明整数；
- Dart 不持有裸指针；
- frame 通过 retain/release 管理；
- 每个调用返回错误码；
- native 线程不回调任意 Dart closure；
- 事件通过受控消息队列回传。

## 7. 缓存策略规格

### 7.1 Keep Score

候选 score 可由以下组成：

- page role；
- 最近访问；
- 重新下载成本；
- 是否可 range；
- 是否接近下载完成；
- decode 重建成本；
- 用户反向概率；
- 文件大小。

### 7.2 Eviction

CacheManager 选择候选后调用：

```dart
Future<EvictionResult> requestEviction(ResourceId id);
```

Coordinator 验证安全条件。结果：

- evicted
- retainedReceiving
- blockedByLease
- blockedByClaim
- blockedByWriter
- notFound

### 7.3 Clear Cache

- 停止新增低优先级 demand；
- 标记清理候选；
- 不同步阻塞 UI；
- active 资源延迟清理；
- 完成后返回实际释放字节。

## 8. Policy Spec

### 8.1 HeuristicPolicy

默认规则：

- current：完整保障；
- transition：编码 + 首帧；
- 前向连续阅读：next 2 页 encoded；
- previous：保留 1 页；
- 频繁反向：previous 扩至 2 页；
- 高温/低内存：只保 current + transition；
- 计费网络：除 current 外不主动下载，除非用户选择性能优先；
- Animated WebP current：目标 frame depth 2～4，依据帧时长和内存；
- GIF current：节流 rebuild；屏外停止 pump。

### 8.2 AdaptivePolicy

输入特征固定版本化。

输出：

- profile id；
- action probability；
- confidence；
- optional bounded rank deltas。

训练：

- 页面或决策事件驱动；
- 不在动画帧循环训练；
- 高温、后台、低电量可暂停更新；
- 每 N 次更新批量落盘；
- 双文件原子替换。

### 8.3 Reward Attribution

每个 reward 必须匹配：

- decisionId；
- source epoch；
- identity；
- policy revision；
- observation schema version。

旧 epoch、重复 event 或超出 attribution window 的反馈被拒绝。

## 9. Telemetry Spec

### 9.1 必须记录

- page request → first ready/present；
- transition start → dominant → present；
- download queue/start/seal；
- decode queue/start/ready；
- upload queue/submit/present；
- cache hit/miss；
- bytes downloaded/wasted；
- frames decoded/presented/dropped；
- stale result rejected；
- memory/thermal state；
- build/raster timings；
- policy decision/reward。

### 9.2 日志格式

推荐 newline-delimited JSON 或 protobuf trace：

- monotonic timestamp；
- wall clock optional；
- sessionId；
- event kind；
- identity hashes；
- revision/epoch；
- numeric payload；
- redacted error。

### 9.3 隐私

默认本地保存有限窗口。远程上传需：

- 用户同意；
- 去除 URL、路径和标题；
- identity 采用会话盐哈希；
- 不上传图片字节或缩略图。

## 10. 性能规格

### 10.1 UI

- build/layout 不触发文件 I/O、网络、容器解析或 decode；
- 页码变化只局部重建；
- 静态大图首次显示不在滚动帧同步生成昂贵 mipmap；
- texture 更新不要求 Widget rebuild。

### 10.2 Network

- current 请求可抢占 queued near，但不强制中断 active receiving；
- range resume 校验 validators；
- 最大并发可动态调整；
- chunk 写入带背压。

### 10.3 Decode

- current reserve worker；
- 每个 decoder 串行 cursor；
- 帧内存预算前置验证；
- decode 结果提交检查 epoch 和 demand revision。

### 10.4 Memory

- 所有 `ui.Image`、native frame 和 texture 有显式释放；
- debug build 提供 lease/claim 泄漏检测；
- 内存警告触发预算收缩和安全驱逐；
- 不通过 MethodChannel 复制完整 RGBA 帧。

## 11. 错误规格

错误分类：

- SourceError
- NetworkError
- ResumeValidationError
- ArtifactCorruption
- UnsupportedFormat
- DecodeError
- TextureError
- MemoryBudgetExceeded
- StaleEpoch
- PolicyError

用户可见行为：

- 当前页失败显示可重试占位；
- 邻页失败静默降级并记录；
- 普通 Animated WebP 打开不得自动启动 native；显式 native 失败后必须 fallback；
- 模型错误不可阻止阅读。

## 12. 测试规格

### Unit

- identity equality/hash；
- epoch rejection；
- writer lease；
- append offset；
- demand diff；
- role window；
- policy guard；
- reward attribution；
- eviction gate；
- GIF index。

### Integration

- HTTP resume；
- partial → final handoff；
- Animated WebP chunk streaming；
- texture create/blit/release；
- background/foreground；
- rotation/resize；
- cancel/reversal；
- cache clear during active session。

### Performance

- 100/500/1000 页章节滚动；
- 4K 静态图；
- 大尺寸 Animated WebP；
- 弱网、高 RTT、无 range；
- 低内存预算；
- 快速连续翻页和频繁反向；
- 60/120 Hz 设备。

### Replay

固定 trace 应产生确定性 DemandPlan。模型测试固定随机种子和 action probability。

## 13. 发布门槛

- 所有 P0/P1 测试通过；
- 无已知 lease/claim/writer 泄漏；
- 无 current starvation 回归；
- 性能基准不低于上一版本门槛；
- 模型关闭时功能完整；
- cache clear 和进程恢复通过破坏性测试；
- 隐私检查通过。

## 2.5 Android Home, Bookshelf and comic details

The Android primary navigation contains Home, Bookshelf and Comic Sources. Home displays update and
reading-history rails using the same fixed-size cover-card contract as the Bookshelf gallery.
Local-folder import is visible; directory maintenance is not part of the Home product surface.
Diagnostics remain collapsed and secondary.

Bookshelf supports custom categories, local/remote filtering, recent/title/page-count/custom
sorting and an independent gallery/list view choice. Custom ordering does not force a list. In
management mode, tapping a comic selects it and exposes move, category membership and copy-info
actions. Delete is isolated from non-destructive actions and requires confirmation. Gallery custom
order uses long-press drag; list custom order uses reorderable rows. A selected category can add
existing shelf comics. Selected chips use highlight alone without a redundant checkmark.

Cover cards support animated thumbnails. While a remote comic is downloading, the cover may be
dimmed and overlaid with a bottom-up completion waterline, percent and completed/total page count.
The presentation receives progress values but does not own DownloadSession.

Comic details display cover, title, liked, shelf and collected state, category membership and
chapters. Chapter order can be reversed. Read chapters are dimmed; a start-to-end swipe restores
unread state without deleting Reader progress.

Reader starts with system and app controls hidden. A page tap toggles top/bottom overlays. Page
slider input submits a bounded Reader command. Pause/speed state is injected into animated media
players; rotation changes presentation only. Pinch/pan and double-tap zoom are page-local, block
PageView scrolling while active and reset after navigation.
