## dev.73 compile-closure requirements

- `pipeline_runtime` must receive `SourceFactory` through composition and must not depend on `bridge`.
- Every `PipelineReaderSessionHost` must receive an explicit factory; no hidden platform/default factory may exist in the pipeline package.
- `local_media_ui` must not import or name `ArtifactCacheStore`, `DownloadSession`, `DownloadSnapshot` or `readerPageDownloadId`.
- Presentation must obtain page identity from `PipelinePageStream.identity` and content classification from `PipelinePageContentKind`.
- Page dimensions may update Reader layout only through a frame-coalesced callback; they must not create download/decode/upload demand.
- dev.70/72 preload windows, lane capacities, request-plan reuse and streaming progress behavior must remain unchanged by compile-closure work.

## dev.72 ownership requirements

1. Reader presentation MUST only publish viewport observations and consume read-only Pipeline projections. It MUST NOT own download, decode, upload, artifact, transport or retry state.
2. Pipeline composition MUST create and dispose the Reader resource session and derive current-page progress from the same `ReaderObs` stream used for demand planning.
3. Home, source browsing and details artwork MUST share the composition-owned source transport and response cache. HTTP artwork MUST use the source thumbnail resolver when available; chapter pages use the page resolver.
4. Request-plan reuse MUST be bounded and invalidated on explicit failure/retry. It MUST NOT retain completed image bodies as a competing cache.
5. The VibeVenera-derived 7/3 encoded prefetch, 2/1 decode-warm window and 5/3/2 lanes MUST NOT be reduced as a substitute for fixing transport/request duplication.

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
- 页码滑杆、旋转、收藏和章节缓存命令；暂停与倍速仅在当前页面确认为动画媒体时显示。
- 默认缩放比例下，分页 Reader 的横向拖动必须由页面导航接管；仅在用户显式放大后，页内拖动/缩放可以暂时接管手势。
- 远程 Animated WebP 可以在 partial 持续增长时开始播放；顶部进度同时区分恢复/已有前缀与当前网络新增部分。
- 阅读设置提供全局自适应布局和纵向拼接；Reader 顶栏提供按漫画的方向、拼接和自适应覆盖。
- 纵向连续模式按页面比例滚动；拼接只移除页间距。RTL slider 的数值方向和端点标签必须与 RTL 翻页一致。

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


## 2.7 首页冷启动与本地图片 I/O

- Flutter 首个可见 surface 不得等待 SQLite、缓存索引或离线页面恢复。书架恢复后，read-state 必须用批量查询，下载徽标必须用 index-only bulk projection；两者不得为每部漫画/每页执行 N+1 查询或 materialize `DownloadSession`。
- 持久封面命中应优先返回完整不可变文件引用，不得在每次首页进入时读取整文件到 Dart heap、重算完整 hash 并同步 flush LRU 元数据。
- 持久封面索引应以一个版本化 compact manifest 在进程内一次恢复；逐项 metadata 只作为崩溃恢复日志。首页性能诊断必须记录 bootstrap、服务打开、封面来源和首帧的单调时间线。
- durable 书架恢复不得以全屏“正在恢复”阻塞已经挂载的 Home；恢复期间必须保持导航可操作，并只呈现非模态同步状态。
- 普通本地静态图片在没有 pipeline/session loader 时应由文件型 ImageProvider 打开。Android SAF `content://` 可复制一次到应用私有持久缓存；后续命中使用该文件。
- 一个普通静态文件只能由渲染用 `Image` 持有一个 provider stream；不得再次手动 `resolve` 同一 provider 观察 ready。ready 必须来自实际 frame 回调。文件路由测试不得等待宿主 decoder 才证明 zero-copy，并应在结束前卸载 provider。
- Animated WebP/GIF、Reader 页面和远程首次下载继续由其既有 decoder、demand 和 artifact owner 管理。
- promoted 页面共享读取可以在权威 `DownloadSession.beginRun` 后启动，以便与临时 workspace restore 并行；页面只能 join。观察者晚于 beginRun 注册时必须通过当前 snapshot 立即补齐状态。
- “zero copy”验收指消除可避免的 Dart 层完整 encoded-file copy；不对平台 decoder 内部 mmap/copy 作不可验证承诺。

## 2.8 外部插件 payload 检查

- Mihon/Venera payload 必须先原子落到稳定本地文件，并在执行前校验实际长度和 SHA-256。
- Mihon inspection 只读取 package、signer、versionCode 与 extension ABI metadata，不得创建 class loader。
- Venera inspection 只做有界 metadata 解析，不执行 JavaScript；仓库 key 与脚本 key 冲突必须拒绝。
- 检查通过后 executor 必须使用同一 payload identity，并继续经过信任、权限、隔离和 session teardown 门禁。

## 2.9 外部插件运行时协议

- Mihon 与 Venera backend 必须实现同一版本化协议；版本不匹配、未知 operation、额外字段或非法 wire type 必须拒绝。
- 协议只允许 source descriptor、browse、comic、chapter、binary resource 与规范化 source settings 数据，不得传递 Widget、Reader、导航、demand、`DownloadSession`、缓存维护、SharedPreferences、JavaScript 对象或 artifact 句柄。
- 来源账号协议只允许规范化 account descriptor、凭据、按声明顺序排列的 Cookie 字段，以及有界 Web 登录快照（最终 URL、标题、Cookie、localStorage）。来源验证、持久化和退出在隔离 runtime 中执行。
- runtime source ID 必须由 host 添加 `mihon:`/`venera:` 命名空间，并与 repository/inspection identity 一致；comic/chapter/page 返回值必须保持请求身份和父子关系。
- host 必须独立执行 timeout、响应字节和真实并发上限。调用方 timeout 后，底层操作真正结束前不得释放并发令牌。
- session close 必须拒绝排队调用、通知隔离 backend 终止活动调用并等待实际工作排空；并发 close 必须加入同一关闭过程。
- Android dedicated-service transport 只能转发版本化基础值消息；process-side Dart endpoint 必须拥有 activation 解析、payload staging、session registry 和错误净化，平台层不得复制这些状态机。
- activation 必须返回 process generation。所有 invoke/cancel/close 都必须携带 generation 与 session ID；服务重启后旧 generation 不得命中复用 session ID，也不得自动重放或重新激活。
- Android Binder 连接本身也必须使用每次显式 bind 唯一的 generation，并安装 death recipient。旧绑定的迟到断开回调不得影响新绑定；绑定阶段全部调用超时后必须允许下一次显式重绑。
- 大响应 packet 必须同时携带 dedicated-root 路径、exact length 与 SHA-256；host 必须在消费时校验三者并在成功或失败后删除 packet。只校验路径/长度不足以作为隔离插件响应的完整性边界。
- 二进制资源使用有界 `Uint8List` wire payload，不允许 base64 扩张或把 Reader artifact authority 交给插件。
- 隔离 backend 的原始传输必须实现版本化 handshake/message-channel 边界。handshake 需要非空 runtime ID、唯一 source ID；每个 response 的 requestId 必须与调用匹配。传输不得依赖进程内 Dart domain/session 对象。
- 隔离侧必须由共享 worker 再次解析 request，拒绝未知 source 和重复活动 request ID，并将任意生态后端异常净化为有界协议错误。
- 可取消 channel 应支持 request-level cooperative cancellation；timeout 可以发送 cancel，但底层 Future 真正结束前 host 不得释放并发额度。
- worker/session close 必须可加入：停止接收新请求，取消活动 token，通知 driver/channel 关闭并等待实际调用排空。
- 平台 activation 必须传递同一个已检查 payload 的 path/length/hash、批准能力和完整 limits。专用隔离服务不可用时必须拒绝激活，不得退回 App 主进程执行。
- 隔离进程入口必须按 exact schema 重解析 activation，并把 host 提供的 payload 流式复制为 process-private 原子文件，同时重算 length/SHA-256；driver 不得在校验后重新打开可被 host 替换的原路径。
- process runtime session registry 必须在进程重启后为空。中断的 browse/detail/chapter/resource 请求只能由调用者以新 session/新 request ID 显式重试，不得自动 replay。
- driver 尚未完成 close 的 session 仍必须占用 process session limit；process close 开始后，仍在校验或创建 driver 的 activation 必须失败并清理 staged payload，不得先返回成功 session 再立即拆除。

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
  DownloadJob/DownloadSession。已持久化且已 promoted 的精确 immutable bytes 只能由该替代 session transport 发起读取，页面消费者可加入
  同一次读取，使 decode 不等待重复 staging；这不赋予 Presentation demand 或 retention 权限。
- cache transport 只接受精确 `DownloadId` 身份。一个 URI 若在同一 manifest 中对应多个页面身份必须绕过
  缓存；range 命中必须验证由精确 DownloadId 与长度派生的 validator，失败时回退到原 source transport。
  持久 artifact 的内容完整性在最初 promotion/storage 时校验，不得在 UI isolate 再做整页哈希。
- cache read 失败必须 fail-open：transport 回退 origin，页面等待正常 session，并记录可归因错误。大 artifact
  回填必须分块，不得以单一巨型 chunk 阻塞 UI isolate。
- Flutter 动图仅 decode target 改变时，旧呈现帧必须保留到替代 codec 首帧呈现；encoded bytes 改变时才
  清空旧帧。进程重启后 decoded frame 不持久化，剩余首帧时间必须拆分为 artifact read/decode/present。
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

The Android primary navigation contains Home, Bookshelf, Comic Sources and Misc. Home displays update and
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

Complete cover/source image bytes use the shared response cache and may be restored from a bounded durable byte store
after process restart. The durable key includes source/comic namespace and available source revision; explicit refresh,
TTL expiry, corruption or capacity eviction produce a normal source reload. Reader page bytes never enter this cover
response store.

Comic details display cover, title, liked, shelf and collected state, category membership and
chapters. Chapter order can be reversed. Read chapters are dimmed; a start-to-end swipe restores
unread state without deleting Reader progress.

Reader starts with system and app controls hidden. A page tap toggles top/bottom overlays. Page
slider input submits a bounded Reader command. Pause/speed state is injected into animated media
players; rotation changes presentation only. Pinch/pan and double-tap zoom are page-local, block
PageView scrolling while active and reset after navigation. Crossing the PageView midpoint must not
replace a page host whose asset identity is unchanged or return already presented neighboring media to
a loading/black placeholder. Regression playback must advance by observed host/current-page state rather
than assuming a fixed pixel distance represents the midpoint on every viewport. Rapid-swipe diagnosis must
correlate stable page identity, resource identity prefix and demand revision before attributing the gap to
artifact lookup, decode, upload, presentation or host lifetime.

External plugin repository metadata may be parsed for Mihon extension packages and Venera JavaScript sources. Venera
indexes accept both `filename` and deployed `fileName`, and a declared `key` becomes stable `venera:<key>` identity.
Executable compatibility requires format-specific, permissioned hosts with explicit teardown that adapt sources to
`BrowsableComicSource`; plugins receive no direct navigation, Reader demand, session or artifact authority. A Mihon
host must validate APK signature/version, extension ABI and normalized entry classes before loading code. The
isolated backend may determine whether an approved loaded entry is a single Source or SourceFactory; metadata inspection
must not instantiate it. Mihon and Venera backends must receive the exact inspected payload path/length and enforce declared
invocation timeout, response-byte, concurrency and runtime-heap limits; inability to enforce a limit is activation
failure, not permission to run unrestricted code. Both ecosystems use the same versioned catalog-operation protocol,
and only the host adapter may turn runtime descriptors/results into zic `BrowsableComicSource` and domain values.
Timeout does not imply backend cancellation or release of an in-flight permit; teardown must signal the isolated
connection and drain the actual operation lifecycle.
Mihon Android packaging must expose each host ABI namespace from exactly one artifact. `extensions-lib` is non-transitive, old Kohesive Injekt and a second AndroidX Preference dependency are forbidden, and release shrinking must retain dynamically referenced host classes. Activation must report an incomplete host ABI before loading extension entry classes.

- Mihon/Venera runtime compatibility: a Mihon APK and its selected 1.4/1.6 Source ABI dex asset must be exact-length/SHA-256 verified and non-writable before a child-first loader observes them. `eu.kanade.tachiyomi.*` comes only from that versioned child loader; AndroidX Preference and other common libraries remain parent-first so Android resources are merged. Venera accepts page-number `load` and cursor `loadNext`, preserves legacy global `res` script behavior, uses a 55-second bounded invocation limit, and routes ordinary HTTP(S) covers plus transient page tokens through the isolated resource bridge.
- Mihon 多章节漫画必须返回来源目录中的全部章节。只有所有兼容目录路径都完成为空，并且 synthetic 章节实际解析出至少一页时，才能创建单一 synthetic 章节；读取真实章节时必须复用或重新匹配对应 `SChapter`，禁止把 manga URL、第一章对象或 synthetic 标记应用到非空目录。目录/页面反射、网络或 reactive 解包错误不得降级为空目录。
- 漫画源管理中的启用来源必须按原生、Mihon、Venera 分类并用分隔线区分。Mihon 同 family 的语言来源在此处默认折叠；Mihon/Venera 安装管理页仅使用顶部“已安装/仓库”切换，不得同时展示左右双栏。
- Mihon/Venera 自定义设置必须归一化为 toggle/text/select/multiSelect/action。Venera 值必须在 runtime 私有存储中保持 boolean/string/list 类型，且只有已批准 persistentStorage capability 才可读写；设置更新不得绕过统一 restart/session 关闭流程。
- `ImportedPageRecord.pageId` 必须非空且在章节内唯一；`sourceId`/URI 只描述资源定位，允许重复。重复 URI 不得导致章节导入失败、页面合并或进度 identity 冲突。
- `mihon:`、`venera-resource:` 等插件私有资源必须由 `downloads` 的注入式 source loader 进入既有 `DownloadJob/DownloadSession`，不得直接交给 `IoTransport`，也不得由详情页执行 scheme 分支。
- Mihon/Venera 页面媒体类型字段只能作为 hint。宿主必须保留字节嗅探和 decoder 校验；只有可识别的原始 URL/文件名才能提前声明 WebP/GIF 等类型。
- Mihon 目录页数未知时可渐进预检，但并发必须有界、结果必须复用 source cache，并只更新当前目录投影。失败必须显示可区分状态，不能永久伪装为实际 0 页。
- Venera 新章节资源必须使用跨 runtime generation 可恢复的受约束 locator，只携带版本化 image/comic/episode identity，并在读取时重新执行来源 `onImageLoad`；legacy runtime token 只作读取兼容。
- Venera 网络桥的重定向必须由宿主有限执行，并在每跳写入响应 Cookie；跨 origin 不得转发 Cookie 或 Authorization，底层 HTTP client 禁止叠加自动跟随。
- Reader progress listener 可能在注册时同步回放 snapshot；Presentation 必须在 build phase 后合并发布 notifier，禁止由同步回调触发构建期 `markNeedsBuild`。


## 2.8 杂项与应用设置

- Android 根导航必须包含第四页“杂项”，并提供快捷设置、设置、关于和 Debug trace。
- 设置根页必须包含数据、网络、书架、阅读、下载、外观六个分区。
- 数据页必须显示当前目录投影，支持导出漫画库元数据备份，并通过统一缓存协调器检查和清理缓存；不得由 Widget 直接遍历缓存目录。
- 外观主题、书架默认筛选/排序/视图、Reader 默认模式/沉浸行为必须作用于真实产品状态，而不是只改变测试或静态文案。
- 下载网络、供电和并发设置必须更新既有持久下载队列策略。
- Debug trace 必须有界；设置页不得通过 trace 反向控制 Reader、pipeline、下载或缓存决策。 trace producer 在 Widget build 中记录时，观察通知必须帧后合并。
- 每漫画设置按来源与漫画复合 identity 持久化，只可覆盖 Reader 方向、纵向拼接和自适应开关。自适应低置信度时必须回退来源/进度默认，不得直接生成预取、下载或解码命令。
## dev.67 Reader control ownership requirements

- The top Reader bar is informational and session-scoped: back, chapter title, optional plain-text page subtitle, transfer progress and per-comic settings only. It must not expose page counts, previous/next, page selection or layout switching.
- Bottom Slider plus direct Reader gestures are the sole page-navigation surface. Global/per-comic settings are the sole layout-selection surface.
- Reader callers may project a plain page subtitle but may not inject arbitrary title/action Widgets or receive `ReaderController` for UI navigation.
- Local-media presentation must use the shared Reader navigation path and must not retain separate page index, previous/next or file-menu state.
- Vertical page requests remain pending until the target lazy child is laid out, the target viewport position is observed and the controller observation is published.
- Session settings/adaptive classification are model code and must not remain embedded in the runtime screen implementation.

## dev.66 resource and continuous-layout requirements

- New Venera chapter pages must use reconstructable `venera-resource:<payload>` locators. Persisted generation-only `venera-resource://token` pages must be refreshed from the owning source before they enter Reader or download sessions.
- Repeated consumers of the same source URI may share only the same in-flight resource operation. Completed bytes remain under existing session/artifact ownership.
- Vertical continuous layout must preserve the complete image. It may update page extent when real geometry becomes available, but it must not crop, stretch, or create a second image stream solely for measurement.
- Reader page number, previous/next, slider and direction commands must remain live across paged/vertical/RTL transitions. Navigation is acknowledged only after the target presentation controller can execute it.


## dev.68 Venera entry and continuous-stitch requirements

- `venera-resource://token` is a generation-scoped legacy identity and must not enter Reader, chapter download, whole-comic download, or plugin runtime invocation. Entry composition must refresh the owning chapter or fail before demand creation.
- A UI `refreshRemote` choice controls ordinary content freshness only; it cannot disable adapter-compatibility migration.
- Deferred Venera resource chapters default to current plus one forward encoded page, at most two download demands, and no automatic Reader network retry. This bound does not authorize an additional byte cache.
- Stitched vertical mode has no separator child. Its static, animated and native-texture media must share a width-fit presentation contract so contain rounding cannot expose the Reader background. Non-stitched mode may render the configured page gap.
- While the active page lacks reliable geometry, its placeholder extent must keep the loading indicator within the active viewport. Measured geometry replaces the placeholder without cropping or stretching.


## dev.69 Venera traffic and continuous-reader requirements

- Ordinary Venera resource responses MUST return image bytes through the native binary packet path. JSON/Base64 byte transport is permitted only for declared response/image transformation hooks.
- GET and HEAD MUST send no entity body or entity headers, regardless of plugin-provided `data`.
- A canceled external runtime request MUST cancel its active native HTTP connection. Ignoring a late response is insufficient.
- Venera Reader demand MUST default to the current page only and one active runtime invocation. Identical role windows MUST NOT produce a new demand revision.
- Per-comic vertical stitch MUST support inherit/on/off. Legacy false values written before the tri-state schema MUST migrate to inherit.
- Stitched vertical presentation MUST create no separator and MUST preserve all source pixels. A small overlap may cover raster rounding but MUST NOT crop the image payload.
- Geometry or viewport changes MUST preserve the visible in-page anchor. No automatic jump is allowed while the user is dragging or the scroll position reports active scrolling.
- Reader loading UI MUST have one viewport-level owner. Page renderers MUST be able to suppress their internal loading indicator.
- Widget tests for lazy lists MUST wait until the target child is constructed before retrieving a single widget.


## dev.70 Venera streaming pipeline requirements

- Source runtime MUST return a request plan separately from image body bytes. Ordinary HTTP(S) bodies MUST stream through the host Transport/DownloadSession path.
- GET and HEAD MUST carry no request body and no source-provided Content-Length, Content-Type or Transfer-Encoding entity header.
- The Venera profile MUST preserve a stable +7/-3 download window. +2/-1 MAY decode ahead; only current/transition MAY upload/present. Runtime request-plan calls remain serialized while network/decode/upload lanes are independent.
- A normal demand detach MUST NOT abort an already receiving download. Explicit cancel/dispose MUST cancel the response stream and release the writer lifecycle.
- Persistent chapter progress MUST become observable after chunks commit. Reader progress MUST be idle for sealed, promoted, failed, disposed and restore-only sessions.
- Trace identity/payload MUST summarize opaque Venera resource/comic/chapter tokens rather than emitting complete Base64 values.
- Sources that require `onResponse` or `modifyImage` MAY use a bounded complete-body runtime fallback; that exception MUST NOT become the ordinary image path.

## dev.71 source-resource composition requirements

- App composition MUST bind complete-byte fallback and streaming response transport atomically through `ChapterResourceAccess` when the download service supports `ConfigurableChapterResourceAccess`.
- Production composition MUST NOT call `setChapterResourceLoader` and `setChapterResourceTransport` separately. Those capabilities remain compatibility surfaces only.
- Source lookup, legacy Venera runtime-locator rejection and `ExternalPluginResourceTransportPool` lifecycle MUST have one App owner. Reader and download widgets MUST receive loaders/projections only.
- Closing the source-resource gateway MUST unbind any still-live download service before closing transports.
- A source-private page MUST prefer the streaming response transport when both streaming and complete-byte fallback are bound. Runtime-transform fallback remains available without becoming the ordinary path.
