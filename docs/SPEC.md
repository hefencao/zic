# zic Product and Engineering Specification

## 1. 版本范围

本文定义 `zic` v1.0 的目标规格，并标出 v0.x 的增量实现顺序。

## 2. 用户能力

### 2.1 书架

用户可以：

- 添加本地文件夹、归档文件或远程章节清单；
- 查看漫画、章节、封面和最后阅读位置；
- 删除书架条目而选择是否保留离线缓存；
- 查看章节下载状态。

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
- 本地和远程来源。

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

## 5. 数据模型

### Comic

- comicId
- sourceId
- title
- authors
- coverAsset
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

目录选择返回 `PickedWebpFolder(directoryPath, displayName, files)`：

- 用户取消返回 `null`，不得枚举目录或创建路由；
- 目录枚举递归过滤大小写不敏感的 `.webp`，并在 UI isolate 之外执行；
- 每个文件的相对 `displayName` 由导入边界显式拥有，不依赖 `XFile.name`；
- 顺序使用确定性的自然路径排序；
- 切换时只保留一个当前播放器，不得同时启动整个目录的动画 codec/texture；
- 上一项、下一项和文件选择使用稳定语义 key，必须测试真实 source 切换。

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
engine detach 或 output release 后禁止调用 `scheduleFrame`。

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
