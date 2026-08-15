# ADR 0282：Download Trace / Snapshot Publication 边界

- 状态：Accepted
- 版本：0.31.0-dev.303
- 触发证据：`zic-debug-trace-2026-08-15T12-56-20.jsonl`

## 背景

dev.302 将一个 accepted `DemandPlan` 的 Net/Decode/Upload mutation 合并进同一 lane transaction，并在 Trace 中确认 `atomicLaneBatch=true`。但是设备复测否证了“重复 lane pump 是合法 revision 主成本”的假设：最常见的页边界 download diff（1 added / 10 changed / 1 removed）`pipelineReconcileTiming` 中位仍约 10.213ms，p90 约 12.03ms，最大约 13.079ms，几乎没有低于 dev.301 同类 11-download burst 的约 10.456ms 中位。

源码审计发现 `DownloadSession._emit()` 同时做两件互不相干的事：记录 Trace，以及无条件 `_notifySnapshot()`。dev.302 虽然在 existing-scope priority migration 路径移除了显式 `_notifySnapshot()`，`_emit(demandApplied)` 仍然隐式发布完整 `DownloadSnapshot`；新增 scope / detach 路径还在 `_emit()` 后显式 notify，因此可能双发布。更广泛地，flow-control、transport read-permit、resume、sourceReady/sourceDisabled、writer rejection 等纯诊断事件也会同步唤醒 PageStream、transfer progress、physical retention 等 snapshot observer。

## 决策

1. 删除混合职责 `_emit()`；以 `_recordTrace()` 作为 diagnostics-only helper。它只写 Trace，永远不得发布 `DownloadSnapshot`。
2. `_notifySnapshot()` 只能由拥有真实 session projection mutation 的状态边界显式调用：state/content/network cursor/ingress projection/claim-count 等真实 snapshot 字段变化，每个 mutation 最多一次。
3. existing-scope priority-only scheduling migration发布 0 个 snapshot；新增 scope 与最终 detach 等 claim-count 生命周期变化各发布恰好 1 次。
4. flow-control/read-permit/resume/source/rejection 等纯诊断发布 0 个 snapshot。它们不得因为“可观测”而获得 media/session publication 权限。
5. committed-byte progress继续使用既有 source-progress quantum 有界发布，避免把每个网络 chunk 重新变成 observer fan-out。
6. dev.302 accepted-plan lane transaction继续保留；本 ADR 不改变3/7、decode previous1/next2、priority、NetLane容量、sourceCanvas、Reader geometry/presentation或dev.299 `current±2` continuity。

## 所有权

- scheduling owner可直接读取/迁移 priority；priority不通过 media snapshot 反向驱动 scheduler。
- `DownloadSnapshot` 是 session/media projection，不是 Trace transport。
- Trace observer 不得通过 helper 隐式取得 snapshot publication 权限。

## 真机证伪

同一明显抖动区域复测时，常见 1-added/10-changed/1-removed 页边界 `pipelineReconcileTiming.reconcileMicros` 应相对约 10.213ms 中位显著下降，同时真实 page-boundary policy revision仍正常提交。若 reconcile 已明显下降而 30–50ms missed-vsync / 肉眼大幅抖动仍大量存在，则冻结本路线，继续下钻剩余 UI-isolate 同步工作或 Flutter/platform frame scheduling；不得回到 geometry、scale、pixel-snap 等已无法解释量级的路线。
