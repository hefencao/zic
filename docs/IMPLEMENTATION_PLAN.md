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
   **Implemented; remote session binding remains next.**
4. Add details preferences, chapter reverse order, read dimming and restore-
   unread swipe. **Implemented for grouped persisted chapters.**
5. Group local/remote chapter records into comic-level detail models.
   **Implemented for persisted chapter records.**
6. Bind authoritative DownloadSession progress and per-chapter download commands to
   the comic-level projection. **Next.**


## Android library management and Reader controls slice

1. Remove Home directory-maintenance presentation while preserving import/source contracts.
   **Implemented.**
2. Reuse exact cover geometry across Home and Bookshelf; decouple view from sort mode.
   **Implemented.**
3. Add management selection, category insertion/move and isolated confirmed deletion.
   **Implemented.**
4. Add custom gallery long-press drag and list reordering. **Implemented.**
5. Add immersive Reader overlays, slider, animation controls, rotation, favorite and cache command.
   **Implemented; chapter cache remains session-scoped unless an external durable callback is supplied.**
6. Add page-local pinch/double-tap zoom with PageView gesture arbitration and navigation reset.
   **Implemented.**
7. Move Reader chapter cache to durable storage and bind authoritative aggregate progress. **Next.**


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
6. Add source account/auth settings, update polling and durable offline download state. **Next.**
7. Evaluate a sandboxed Mihon/Keiyoushi adapter after defining plugin ABI, permissions, lifecycle and
   compatibility policy. **Later; do not embed extension code in Widgets.**

## Android remote-source reliability patch

1. Make generated Android Internet permission reproducible across bootstrap, run and release build.
   **Implemented in 0.21.1-dev.25.**
2. Preserve complete source URI/cause/stack details and expose selectable/copyable diagnostics.
   **Implemented.**
3. Bound connection wait and retry one transient MangaDex network failure without unbounded loops.
   **Implemented.**
4. Validate native platform HTTP adapters for proxy/VPN parity before changing the core streaming
   transport. **Next; no TLS or hostname bypass is permitted.**

## Unified comic-details and refresh slice

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

