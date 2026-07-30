# zic Implementation Plan

## 1. 实施原则

- 先建立可测状态机，再接入真实网络和 decoder。
- 先实现 deterministic heuristic，再实现 adaptive policy。
- 先完成 Android 性能闭环，再做 iOS parity。
- 每个阶段都有可运行 vertical slice，不长期维护不可运行大分支。
- 所有优化都要有 trace 和基准。

## 当前 fixed-overlay dev.21 候选收敛门禁

- 唯一基线是上一完整候选与 `fixed.zip` 五文件覆盖后的合并树，映射和 ingress
  hash 记录于 `docs/FIXED_OVERLAY_BASELINE.md`。
- 普通 WebP 打开固定从 Flutter codec 开始，native 必须显式二次确认。
- picker、route、容器校验、codec 页面状态和文件夹切换分别测试。
- 异步测试同步到 `WebpPreviewState` 或受控 future，不推进猜测的固定 frame 时长。
- Reader app 使用 `LiveCoordinator + DownloadRegistry`，播放器只读取 promoted
  artifact；viewport 重建或销毁前必须 detach 旧 demand plan。
- 导入文件夹必须归一化为 catalog chapter record，并通过 loader transport 和
  DownloadSession 进入 Reader；记录与最后阅读位置由持久目录库保存，禁止保留独立目录浏览器的直接文件读取权威。
- 本地目录递归枚举不得在 UI isolate 执行，只创建当前可见图片的播放器；Android 必须沿 SAF document tree/content URI grant 读取，桌面使用 isolate 文件扫描；格式由文件头嗅探，完整 codec 负责最终校验。

## 当前应用主线（0.31.0-dev.49）

- 目标重建回归必须先证明 decode target 实际变化；仅改变容器尺寸但 raster target 不变时，不得把“不重建 codec”判定为产品错误。
- Mihon/Venera activation wire 必须在隔离进程入口再次严格解析；process-side driver 不得直接信任 host 进程中的对象或未声明字段。
- 批准 payload 必须在隔离进程内按 length/SHA-256 流式重验并原子提升为 process-private 文件，driver 只能打开该副本；session 关闭后由 process host 删除。
- runtime process host 必须拥有 session registry、activation 串行化、invoke/cancel/close 路由和 joinable shutdown。进程死亡/重启后不得自动重放中断的 catalog 请求。
- 普通本地静态图片的文件路由必须是可独立验证的纯映射；zero-Dart-copy 测试不得启动宿主平台 codec 或依赖测试 runner 的图片流收尾。
- 受控 GIF/WebP 状态机只依赖 `FlutterAnimatedCodec` 契约。生产 adapter 使用 `ui.instantiateImageCodec`，测试 adapter 必须确定性返回帧；不得让不可取消的 engine Future 成为状态机单元测试前提。
- 动画首帧 ready 必须等待真实 `endOfFrame`。替代 decode target 未呈现前保留旧帧；generation 失效或 dispose 时必须释放新旧 frame、codec 和 Timer，失败断言也必须执行同一 teardown。
- `local_image_preview_test.dart` 和冷 Reader artifact 测试使用有真实时间上限的事件循环轮询，而非固定帧数推断外部 I/O/codec 已完成。
- 将 protocol-v1 的服务端所有权收敛为 `ExternalPluginRuntimeWorker`：隔离边界内再次解析请求、验证 source/request identity、净化错误、跟踪真实调用并确定性关闭。
- 为 raw runtime channel 增加可选的 request-level cooperative cancellation；timeout 只结束调用者等待，底层 Future 退出前 host permit 不释放。
- Mihon/Venera activation envelope 传递 exact payload path/length/hash、approved capabilities 和 runtime limits；Android host adapter 统一 activation/invoke/cancel/close。
- Android native bridge 在隔离执行服务未安装时明确 fail-closed；不得退回主进程 class loading 或无约束 JavaScript 执行。
- 下一阶段分别实现 Mihon dedicated-process driver 与 Venera sandbox driver，它们必须复用 worker 和 protocol conformance fixture。

- 保留 Home/Bookshelf 的 Presentation 拆分，但禁止在 `apps/app/lib` 定义资源缓存、章节下载、页面保活或整本调度算法。
- `resource_cache` 继续统一管理封面/图片响应、漫画详情、章节元数据和搜索结果。只有完整 `imageBytes` 可通过注入的 byte store 持久化；章节页面仍不进入该平面。
- 封面持久键必须包含完整 `ResourceCacheKey` 与可用 `sourceRevision`，保留命名空间失效、TTL、容量限制和显式刷新。关闭缓存时先停止接收新工作，再排空已有请求及持久提交；统一维护需分别展示/整理内存响应、持久响应和页面 artifact。
- Reader 的页面/缩放 host 按稳定 asset identity 建立。翻页中点改变 current role 只能触发状态更新和缩放重置，不得销毁已加载媒体子树；Presentation 仍不得通过 keep-alive、私有 LRU 或相邻页预热竞争 pipeline policy。
- `downloads` 管理独立页面 artifact 下载、promoted handoff 及整本队列；不完整章节继续由“章节元数据 + 任意页面 artifact 子集”表示。
- `catalog` 新增 Mihon repository 与 Venera source index 的纯元数据兼容层。Venera 同时兼容 `filename`/`fileName` 并优先保留仓库 `key`；Mihon host 后续必须检查 `tachiyomix.extensionLib` 等 APK ABI 元数据。外部 APK/Kotlin 与 JavaScript 执行必须分别位于受限 host，返回有显式 `close()` 生命周期的普通 `BrowsableComicSource`，不得获得导航、Reader、demand 或 artifact 权限。
- 外部插件的共享信任/权限/版本/ABI/隔离/session 门禁及 immutable-payload inspector 已实现；Android `MihonApkMetadataReader` 同时返回入口类元数据。Mihon/Venera 现共享版本化 browse/detail/chapter/resource wire protocol 和统一 `BrowsableComicSource` 适配层；host 对 timeout、响应字节和真实并发二次限流。下一阶段只在对应 isolated backend 内实现 class loader 或 JavaScript engine，不得复制 catalog/domain 映射或泄漏 Reader/download/artifact API。
- Reader 快速切页 trace 已有确定性回放分析：由 `downloads` 生成精确 page/DownloadId identity，分别记录 transition revision 与实际产出呈现帧的 work revision，还原 artifact 来源、decode/upload 排队与执行、present、first frame 和 host remount；中点前已呈现的邻页计为零 transition wait。任何 retention 调整必须先由该分析定位 owner，再在 pipeline/session/media 层实施。
- App durable composition 只接受显式 `ManagedChapterDownloadService` 作为页面 artifact store/maintenance；普通 `ChapterDownloadService` 保持较窄契约，避免把缓存维护强加给仅提供下载命令的适配器。
- 冷启动 Reader 命中已 promoted 页面 artifact 时，权威替代 session 进入 queued/receiving 即启动唯一精确读取；页面消费者只加入该读取并可立即 decode，替代 session 仍需完成 receive/seal/promote。禁止页面自行创建缓存/网络 demand 或新增 Presentation 私有缓存。
- Flutter 动图 `ready` 只能表示真实首帧已呈现，容器解析或 codec 创建不得提前发布 ready。仅因 decode target 改变而重建 codec 时必须保留最后呈现帧，直到替代帧真正呈现；encoded identity 改变时才立即清空。
- 首页冷启动必须先挂载 Flutter bootstrap surface，再异步打开持久服务；禁止在 `runApp` 前遍历恢复所有离线页面。read-state 使用单次批量查询，首页下载状态使用一次 index-only bulk projection，不得为徽标创建 session 或触碰页面文件；精确页面命令才 materialize/restore session。
- 完整封面 warm hit 和普通本地静态图片优先传递不可变文件引用到 engine-facing ImageProvider，避免整文件进入 Dart heap。`content://`、动画和 Reader 页面继续使用各自受控字节/session 边界；不得把“避免 Dart copy”夸大为平台解码绝对 zero-copy。
- Mihon/Venera inspector 必须针对同一不可变本地 payload 做实际长度和流式 SHA-256 检查。Mihon 元数据读取不得 class-load APK；Venera source key 发现不得执行 JavaScript，仓库 key 与脚本 metadata 必须一致。
- 普通本地静态图片只能由 engine-facing `Image` 持有一个 `ImageStream`；不得为了观察 ready 再手动 `resolve` 同一 provider。ready 由 `frameBuilder` 的实际帧发布，文件路由测试只验证不进入 Dart 整文件字节路径并必须显式卸载。
- promoted artifact 共享读取以权威 `DownloadSession.beginRun` 为最早启动信号，允许在临时 workspace restore 期间读取持久 artifact；页面仍只能 join，不能自行触发 cache/network demand。
- Mihon/Venera isolated backend 必须通过 `ExternalPluginRuntimeMessageChannel` 交换 protocol-v1 基础值/`Uint8List` 消息。handshake source identity、schema 和每次 response requestId 在跨边界处验证；不得返回进程内 zic domain/session 对象。

## 2. 阶段划分

## Phase 0：仓库与工程基线

### 目标

建立可持续迭代的 monorepo、CI、代码规范和性能基准入口。

### 任务

- 创建 Flutter app 和 Dart packages。
- 创建 Rust workspace 和 FFI smoke test。
- 配置 format/analyze/test。
- 配置 Android debug/release 构建。
- 配置 golden/performance test runner。
- 建立 ADR、错误码和日志 schema。
- 建立 fake clock、fake transport 和 deterministic scheduler。

### 验收

- Android 模拟器和真机可启动空应用。
- Dart 调用 Rust `zic_version()` 成功。
- CI 执行 Dart test、Rust test 和 Android build。

## Phase 1：Domain、Catalog 与静态 Reader Vertical Slice

### 目标

完成不含智能策略和动画 native 的最小阅读闭环。

### 任务

- 定义 Comic/Chapter/PageAsset/ReadingProgress。
- 实现本地目录和 manifest source。
- 实现 Reader LTR/RTL PageView。
- 实现 ReaderObs。
- 实现 Content/Download/Decode identity。
- 实现静态 ImageProvider 适配。
- 记录首帧和切页 telemetry。

### 验收

- 可加载 100 页本地章节。
- RTL/LTR 切换正确。
- 快速翻页无同步文件读取进入 build/raster。
- identity 和进度恢复测试通过。

## Phase 2：Transport、Artifact 与 DownloadSession

### 目标

建立统一编码字节权威和可恢复下载。

### 任务

- 实现 ComicSource/ByteStreamResponse。
- 实现 DownloadSession 状态机。
- 实现 writer lease 和 committedLength 校验。
- 实现 partial artifact、flush、seal、checksum、promote。
- 实现 SQLite cache index。
- 实现 range resume 和 validator 校验。
- 实现内容嗅探。
- 实现启动扫描和 orphan 安全规则。

### 验收

- 任意 chunk 边界写入正确。
- 进程中断后可恢复 partial。
- stale writer chunk 被拒绝。
- active artifact 不被扫描器删除。
- 无 range 来源普通 detach 不会自动重下。

## Phase 3：Pipeline、Role Window 与 Scheduler

### 目标

将 UI 状态转为统一 demand，并与 session 生命周期解耦。

### 任务

- 实现 PipelineController。
- 实现 PageRole、RoleResolver。
- 实现 HeuristicPolicy。
- 实现 ResourceRanker 和 PolicyGuard。
- 实现 DemandPlan/DemandDiff。
- 实现 Coordinator。
- 实现 network/decode/upload/maintenance lane。
- 实现 current reserve 和任务合并。

### 验收

- current/transition/near 角色在 trace 中正确变化。
- `onPageChanged` 前 target 可获得 transition demand。
- current 水位不足时 near 自动降级。
- UI helper 不拥有 session。
- 固定 Reader trace 产生确定性 DemandPlan。

## Phase 4：Rust Animated WebP Core

> 状态：`0.18.3-dev.21` 已完成增量 source、真实 WebP decode、frame ownership、
> blend/dispose、metadata、有限/无限循环、显式 cursor step，以及从固定上游源码生成 Android 三 ABI libwebp/media_core；
> Kotlin texture 与设备级生命周期测试仍继续推进。

### 目标

实现可增长字节源、native cursor 和 frame ownership。

### 任务

- 选择并封装 WebP 解码库。
- 实现 source create/append/seal/reset。
- 实现 source epoch 和 offset 验证。
- 实现 cursor create/decodeNext。
- 实现 frame retain/release/info。
- 实现 frame composition 和 loop metadata。
- 实现内存预算检查。
- 实现 Rust 单元和 fuzz 测试。

### 验收

- 分块输入与完整文件解码帧序列一致。
- 任意 chunk 边界不崩溃。
- stale epoch append/decode 被拒绝。
- frame 引用计数无泄漏。
- 受损文件返回结构化错误。

## Phase 5：WebP DecodeSession 与 Android Texture

### 目标

将 native frame 安全接入 Flutter 显示。

### 任务

- 实现 WebPDecodeSession。
- 实现 FrameHolder 和 frame depth。
- 实现 decode/upload claim。
- 实现 Kotlin texture registry。
- 实现专用串行 blit 线程。
- 实现 texture create 与 first blit 分离。
- 实现 scheduleFrame。
- 实现后台/前台和 texture release 排空。
- 实现 Flutter fallback renderer。

### 当前候选实现（仍需 Flutter/Android 验证）

- 已增加 `texture_bridge`、`SurfaceProducer`、串行 blit lane 和 JNI RGBA blit；
- external texture 使用源画布比例的 contain viewport，不直接拉伸到页面 viewport；
- 已建立 Dart 临时 owner 与平台当前帧 owner 的双层 retain/release；
- 已增加 queue/upload/deadline/memory/fallback telemetry；
- 已通过 `ReaderPageBuilder` 将 Animated WebP 播放器接入 Reader 页面；
- Reader demand 已由真实 `LiveCoordinator` 下载到 promoted artifact，asset/file/http
  transport 与 manifest `DownloadId` 共享身份；
- `DownloadSession` 提供 observer-safe snapshot，`ReaderBinding.detach` 清理旧计划；
- 已重构 picker、路由、容器校验和预览状态的测试边界。

此候选不得在目标 Flutter 测试、analyze、Rust/Android native 构建完成前升级版本
或标记为稳定基线。

### 验收

- 当前页 Animated WebP 可在下载封口前播放。
- PageView 停止后动画不停止。
- texture resize 不在每帧执行。
- release 不与在途 blit 竞争。
- 后台返回后 session 可继续或安全恢复。
- 三个指定 app 测试、完整 Flutter/Dart/analyze 和可用 native 检查全部通过。

## Phase 6：Transition、播放时序与缓存

### 目标

完成高质量切页、帧水位和多层缓存。

### 任务

- 实现 idle/dragging/overlap/dominant/settling。
- 实现 present freeze/resume。
- 实现未 present 帧时长重置。
- 实现 encoded memory cache。
- 实现 decoded frame cache。
- 实现 device budget resolver。
- 实现 CacheManager 和 safe eviction handshake。
- 实现 clear cache 异步流程。

### 验收

- transition 目标页 prepared 时无空白切换。
- cancel/reversal 不污染 current。
- 内存警告触发预算收缩，无 active 资源误删。
- cache clear 返回实际释放字节。
- 1000 页压力测试无持续增长泄漏。

## Phase 7：Telemetry 与 Heuristic 调优

### 目标

建立足够可靠的数据，证明策略效果并为学习准备。

### 任务

- 实现统一 event schema。
- 实现 monotonic trace。
- 实现 decisionId/policyRevision/epoch 归因。
- 实现性能 overlay 和 trace 导出。
- 实现 benchmark corpus。
- 调整 heuristic profile。
- 建立 current starvation、wasted bytes、present gap 指标。

### 验收

- 所有资源任务可追溯到 demand revision。
- stale result rejection 可统计。
- 同一 trace 可离线重放。
- heuristic 在目标 corpus 上达到性能门槛。

## Phase 8：Adaptive Policy Shadow

### 目标

模型只做影子决策，不影响真实资源。

### 任务

- 实现 FeatureBuilder 和 schema version。
- 定义有限 DemandProfile。
- 实现 LinUCB 或 Linear Thompson Sampling。
- 实现 PolicyModelStore。
- 实现 RewardAggregator。
- 实现 shadow decision 日志。
- 实现模型异常回退。

### 验收

- shadow 输出不改变实际 DemandPlan。
- 模型参数持久化和原子更新正确。
- 重复、旧 epoch 和超时 reward 被拒绝。
- 模型文件损坏时自动回退。

## Phase 9：受控在线学习

### 目标

在硬约束内让模型选择安全 profile。

### 任务

- 实现低比例安全探索。
- 当前页最低保障排除探索。
- 高温、低内存、计费网络关闭探索。
- 实现用户开关和模型重置。
- 实现 A/B 本地对比和回滚标志。
- 实现离线 replay evaluator。

### 验收

- 关闭模型时与 Phase 7 行为一致。
- 模型输出无法突破 PolicyGuard。
- 性能和资源指标不劣于 heuristic 门槛。
- 模型更新不会发生在每帧循环。

## Phase 10：GIF 与 iOS

### 目标

补齐格式和平台能力。

### 任务

- 实现 GIF incremental index/runtime fallback。
- 实现 rebuild 节流。
- 基准评估 native GIF cursor。
- 实现 iOS Flutter texture 或高效 image renderer。
- 实现 iOS lifecycle/device telemetry。
- 统一 Android/iOS conformance tests。

### 验收

- GIF current 页可边下载边展示可用快照。
- 屏外 GIF 不持续消耗 CPU。
- iOS 功能和 identity/session 语义与 Android 一致。

## Phase 11：发布硬化

### 目标

完成生产发布要求。

### 任务

- 故障注入和断电恢复。
- 长时间 soak test。
- 内存和 texture 泄漏检查。
- 隐私与日志脱敏检查。
- 可访问性和本地化。
- 发布性能基线和回归门槛。
- crash fallback 和用户可见错误体验。

### 验收

- 发布门槛全部满足。
- 无 P0/P1 已知问题。
- 模型完全关闭仍可稳定使用。

## 3. 首批 20 个实现任务

1. 初始化 monorepo 和 package graph。
2. 建立 `domain` ID 值对象。
3. 建立 ReaderObs。
4. 建立 fake monotonic clock。
5. 建立 deterministic priority scheduler。
6. 建立 DownloadSession 状态机。
7. 建立 writer lease。
8. 建立 Artifact partial writer。
9. 建立 append offset 校验测试。
10. 建立 partial → final promote。
11. 建立 SQLite cache schema。
12. 建立本地目录 ComicSource。
13. 建立 HTTP ComicSource fake server 测试。
14. 建立 RoleResolver。
15. 建立 HeuristicPolicy。
16. 建立 DemandPlan/DemandDiff。
17. 建立 Coordinator registry。
18. 建立静态 Reader vertical slice。
19. 建立 trace event schema。
20. 建立首个 100 页性能基准。

## 4. 推荐首个 Sprint 交付

第一个 Sprint 只做以下闭环：

```text
本地 manifest
  -> Reader PageView
  -> ReaderObs
  -> HeuristicPolicy
  -> DemandPlan
  -> fake Coordinator
  -> 静态页面显示
  -> trace 输出
```

不在第一个 Sprint 中实现：

- Rust WebP；
- texture；
- adaptive model；
- GIF；
- 复杂缓存 UI。

## 5. 代码审查门槛

任何资源相关 PR 必须回答：

1. identity 是什么？
2. 所有者是谁？
3. epoch 如何验证？
4. detach 后资源如何处理？
5. active claim 如何排空？
6. 是否在 UI isolate 执行重型工作？
7. 如何测试 stale result？
8. 如何观测性能变化？
9. 失败时如何回退？
10. 是否改变了 current 优先级？

## 6. 完成定义

任务完成需要：

- 实现；
- 单元测试；
- 必要集成测试；
- trace/metric；
- 文档更新；
- 无新增 analyzer warning；
- 性能敏感改动提供前后基准。


### Local-media 分层门禁

- App 页面不得实现目录递归、文件头 I/O 或 Android URI 访问。
- `packages/local_media` 拥有平台无关契约和桌面扫描。
- `packages/local_media_bridge` 拥有 Android SAF 与 resolver stream fallback。
- 修改 Flutter plugin 后必须通过 `./tool/clean.sh` 做干净构建。

## Android library vertical slice

1. Persist categories, comic preferences, custom order and chapter read state
   in the existing library store. **Implemented.**
2. Replace the demo-only home with Home/Bookshelf primary navigation while
   retaining diagnostic routes. **Implemented.**
3. Add animated cover cards and reusable download waterline presentation.
   **Implemented; 0.25.0-dev.29 binds the shared cover to authoritative persistent task snapshots.**
4. Add details preferences, chapter reverse order, read dimming and restore-
   unread swipe. **Implemented for grouped persisted chapters.**
5. Group local/remote chapter records into comic-level detail models.
   **Implemented for persisted chapter records.**
6. Bind per-chapter durable download commands to the comic-level projection.
   **Implemented in 0.23.0-dev.27; authoritative cover progress and cancel/retry/delete management
   are implemented in 0.25.0-dev.29.**


## Android library management and Reader controls slice

1. Remove Home directory-maintenance presentation while preserving import/source contracts.
   **Implemented.**
2. Reuse exact cover geometry across Home and Bookshelf; decouple view from sort mode.
   **Implemented.**
3. Add management selection, category insertion/move and isolated confirmed deletion.
   **Implemented.**
4. Add custom gallery long-press drag and list reordering. **Implemented.**
5. Add immersive Reader overlays, slider, animation controls, rotation, favorite and cache command.
   **Implemented; 0.23.0-dev.27 supplies the durable chapter-download callback.**
6. Add page-local pinch/double-tap zoom with PageView gesture arbitration and navigation reset.
   **Implemented.**
7. Move Reader chapter cache to durable storage. **Implemented in 0.23.0-dev.27; authoritative
   aggregate progress and download management are implemented in 0.25.0-dev.29.**


## Remote comic source browser slice

1. Add a third primary Comic Sources destination with a top management entry and bottom enabled-source
   switcher. **Implemented.**
2. Define catalog-owned browse/resource contracts and inject source implementations into App
   composition. **Implemented.**
3. Persist source enablement/order with a schema 2 to 3 migration. **Implemented.**
4. Implement one real remote source and map browse/detail/chapter manifests into the durable library
   plus existing Reader artifact ingress. **Implemented with MangaDex.**
5. Persist page identity independently of mutable remote delivery URLs and reconcile progress across
   refresh. **Implemented.**
6. Add source account/auth settings and update polling. Durable chapter offline state is implemented
   in 0.23.0-dev.27 and management/cancel/retry/delete UI in 0.25.0-dev.29; source update polling remains next.
7. Define Mihon/Venera repository metadata compatibility and the isolated host/session ABI before
   executable integration. **Metadata parsers and explicit host/session lifecycle are implemented in
   0.31.0-dev.38; shared trust/capability/quarantine/runtime-registry gates are implemented in
   0.31.0-dev.39; deterministic Reader transition replay is implemented in 0.31.0-dev.40; Android APK/Kotlin and JavaScript sandbox executors remain next.**

## Android remote-source reliability patch

1. Make generated Android Internet permission reproducible across bootstrap, run and release build.
   **Implemented in 0.21.1-dev.25.**
2. Preserve complete source URI/cause/stack details and expose selectable/copyable diagnostics.
   **Implemented.**
3. Bound connection wait and retry one transient MangaDex network failure without unbounded loops.
   **Implemented.**
4. Validate native platform HTTP adapters for proxy/VPN parity before changing the core streaming
   transport. **Next; no TLS or hostname bypass is permitted.**

## Superseded unified comic-details and refresh slice

1. Route source browse, Home updates, reading history and Bookshelf through one details component.
   **Implemented in 0.22.0-dev.26.**
2. Merge complete upstream manifests with persisted chapters by source-aware chapter identity.
   **Implemented; refresh never auto-imports a newly discovered chapter.**
3. Preserve persisted chapters that disappear temporarily from a successful source response.
   **Implemented as local-retained rows.**
4. Persist source authors/description/cover metadata with backward-compatible JSON decoding.
   **Implemented.**
5. Add pull-to-refresh while retaining source/store/Reader ownership boundaries.
   **Implemented for remote manifests and local-folder rescan.**
6. Add durable source update timestamps and update ingestion for the Home update rail.
   **Next.**


## Two detail owners, whole-comic shelf and source migration slice

1. Restore separate remote and local state owners while sharing stable details components and one exact
   route decision. **Implemented in 0.23.0-dev.27.**
2. Persist whole-comic metadata/catalog independently of chapters and migrate SQLite to schema 4.
   **Implemented.**
3. Make liked/shelf/collected/category actions whole-comic operations; make the chapter trailing action
   a durable download. **Implemented.**
4. Reuse complete persistent chapter artifacts in Reader after restart. **Implemented.**
5. Copy cross-source preferences and only exact chapter/progress/read matches after resolving target
   manifests; retain original source and bytes. **Implemented in 0.23.0-dev.27; schema 5 later removed
   the native-ID-only storage restriction.**
6. Migrate all legacy keys to source-composite schema 5. **Implemented in 0.24.0-dev.28 with
   compatibility decoding and auditable ambiguity reporting.**
7. Add download management/cancel/retry/delete and authoritative aggregate progress.
   **Implemented in 0.25.0-dev.29 using the existing DownloadSession/artifact authority.**
8. Surface auditable legacy migration issues with copy/export, pending/all filtering and explicit
   acknowledgement that never deletes the retained record. **Implemented in 0.26.0-dev.30 with schema 6.**
9. Add target-source side-by-side candidate comparison before migration. Search and manual-ID selection
   already exist; cover/author/chapter-sample comparison remains next.

## Cover management and download projection slice

1. Keep single-item delete and category migration on each management-mode cover; reserve the separate
   management surface for long-press multi-selection and batch operations. **Implemented in 0.27.0-dev.31.**
2. Preserve category migration and sort choices as bounded popup menus; use a separate custom-order drag
   handle so long press remains multi-select. **Implemented.**
3. Subscribe details and covers to authoritative chapter task state across route recreation. **Implemented.**
4. Distinguish single-chapter progress from whole-comic aggregate progress and clear the waterline at
   terminal completion. **Implemented.**
5. Add whole-comic download while retaining per-chapter DownloadSession/artifact ownership and cancellation.
   **Implemented.**
6. Remove cover metadata rows, overlay title, keep reading progress in details, and coalesce rapid route taps.
   **Implemented.**
7. Add durable queue scheduling, concurrency limits, pause/resume and network/power policy for whole-comic downloads. **Implemented in 0.28.0-dev.32.**
8. Add side-by-side target-source migration candidate comparison before confirmation. **Next.**

- 首页持久封面索引由 storage-owned compact manifest 一次加载；逐项 JSON 仅用于 crash recovery/migration。启动 trace 必须区分 bootstrap、service open、cover source origin 和 first frame，不得反向控制加载策略。
