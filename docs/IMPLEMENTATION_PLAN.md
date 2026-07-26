# zic Implementation Plan

## 1. 实施原则

- 先建立可测状态机，再接入真实网络和 decoder。
- 先实现 deterministic heuristic，再实现 adaptive policy。
- 先完成 Android 性能闭环，再做 iOS parity。
- 每个阶段都有可运行 vertical slice，不长期维护不可运行大分支。
- 所有优化都要有 trace 和基准。

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

### 验收

- 当前页 Animated WebP 可在下载封口前播放。
- PageView 停止后动画不停止。
- texture resize 不在每帧执行。
- release 不与在途 blit 竞争。
- 后台返回后 session 可继续或安全恢复。

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
