# ADR 0281：accepted DemandPlan 的原子 lane reconcile 事务

## 状态
Accepted，建立在 ADR 0280 的 semantic revision/liveness 分离之上；不改变 Reader 资源窗口、priority 或 lane 容量。

## 设备证据
12:21 dev.301 Trace 已证明 ADR 0280 的 semantic-no-op revision cascade 机械消失，但明显纵排抖动仍存在。1460 个真实 Flutter FrameTiming 中 43 个 interval 超过 30ms；按最近 Reader interaction 归类，active scrolling/dragging/settling 中有 37 个，且 28/37 在一个真实 `policyDecision` 后 100ms 内。合法页边界常产生 11 个 download scheduling mutation、4 个 decodeDemand 与 2 个 uploadDemand。含 11 个 download 更新的同步 burst 中位约 10.456ms、p90 约 14.110ms、最大约 15.372ms，已经足以与正常 build/raster 叠加后跨过约 16.4ms vsync。

## 根因边界
ADR 0280 解决“是否应提交 revision”；本问题发生在 revision 已经合法提交之后。`LiveCoordinator.reconcile()` 把一个权威 plan 拆成 download/decode/upload 多个 mutation；`DownloadTransferOwner` 的 NetLane priority/demand 更新以及 DecodeLane/UploadLane 的 submit/follow/replace 都会立即 `_pump()`。因此同一个 accepted plan 会反复扫描 pending/active、admission/preemption 与 bucket/transport lease intermediate state。所有这些工作仍在 Reader observation 经 microtask 进入的同一 Dart UI isolate 上，Flutter build/raster timing并不包含这段控制面同步开销。

另一个同源耦合是 `DownloadSession` 的纯 priority migration：调度 owner 已经直接更新 NetLane，但 `_setDemandPriority()` 仍广播完整 `DownloadSnapshot`，使 PageStream、transfer progress、physical retention 等不消费 priority 的内容/生命周期 observer 被同步唤醒。

## 决策
1. `TaskLane.batch(action)` 是 lane scheduling transaction primitive。mutation 立即更新权威 lane state，但 outermost batch 退出前只记录 pump request，不运行 admission/preemption scan。
2. `LiveCoordinator.reconcile()` 将 NetLane、DecodeLane、UploadLane 的一个 `PipelineDelta` 包在同一 nested batch 中；download/decode/upload diff、liveness refresh、source wakes 与 budget enforcement全部提交后，各 lane 才对最终 authoritative state pump。
3. batch 不改变 priority、FIFO、preemption、transport lease、bucket、decode/upload并发或任何 Reader window；batch 外的单独 mutation 保持原 eager scheduling 语义。
4. `DownloadSession` 新增 scope 仍广播 demanded/demandCount 生命周期变化；纯 existing-scope priority migration只记录 scheduling trace，不广播完整 media/session snapshot。读取 `session.snapshot` 仍返回最新 effectivePriority。
5. 新增 `pipelineReconcileTiming` 仅记录 accepted revision 的 reconcile 时长及 diff cardinality。该诊断与 `readerFrameTiming` 一样不得因为自身记录而请求 Flutter frame，也不得成为 policy 输入。

## 可证伪条件
下一次同区域设备 Trace 应先验证真实 page-boundary revision 仍正常提交，且 `pipelineReconcileTiming.reconcileMicros` 相比 dev.301 的 10–15ms burst显著下降。若 atomic lane transaction 已命中但 active 仍持续出现 30–50ms missed-vsync，则冻结本路线并转剩余 UI-isolate 同步任务 / Flutter-platform frame scheduling；不得回到 geometry、scale、pixel snap、扩大 decode/prefetch 或修改 priority。
