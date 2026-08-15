# dev.303 Download Trace / Snapshot Publication 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.302_atomic-lane-reconcile-transaction.zip`
- 设备证据：`zic-debug-trace-2026-08-15T12-56-20.jsonl`
- 用户现象：明显纵排抖动仍存在，量级远大于1–2px。

## dev.302 被证伪的部分

Trace 中 `atomicLaneBatch=true` 已证明 lane transaction 本身生效，但常见合法页边界的 1-added/10-changed/1-removed download diff 仍为约 10.213ms 中位、12.03ms p90、13.079ms max；dev.301 同类 11-download burst 中位约 10.456ms。重复 `_pump()` 因此不是这 10ms 级同步成本的主要来源。

## 直接源码根因

`DownloadSession._emit()` 在记录任何 TraceEvent 后无条件 `_notifySnapshot()`。这使 dev.302 的注释和真实行为相反：

- existing-scope priority-only `_setDemandPriority()` 虽没有显式 notify，但 `_emit(demandApplied)` 仍发布 snapshot；
- 新 demand scope 与 detach 在 `_emit()` 后还有显式 `_notifySnapshot()`，所以可双广播；
- `recordFlowControl()`、`recordTransportReadPermit()`、`recordResume()`、playable-prefix/source trace、writer rejection 等纯诊断也发布 snapshot。

这会在一次 11-download priority migration 中同步扇出多组 session observer，正好解释 dev.302 lane pump 已合并而 1/10/1 reconcile 仍保持约 8–13ms 的设备证据。

## Listener 所有权审计

生产 snapshot observer 主要消费实际 media/session lifecycle：PageStream projection、transfer progress、promoted/hot retention、artifact handoff/read pool、physical transfer progress等。scheduler owner已经直接持有 demand claim/effective priority；没有理由让 existing-scope priority-only migration借完整 media snapshot传播。纯 transport/source diagnostics 更不拥有 snapshot publication 权限。

## 收口

- `_emit()` 被删除，替换为无副作用 `_recordTrace()`。
- state/content/network cursor/ingress projection/claim-count 等真实 snapshot mutation 在拥有该变化的方法里显式 `_notifySnapshot()`。
- priority-only及纯诊断为零 publication；attach/detach恰好一次。
- committed progress继续按既有 quantum publication。
- 测试显式断言 attach 1 次、priority-only 0 次、detach 1 次，并断言 flow-control/read-permit/resume diagnostics不发布 snapshot。

## 未改变

不修改 policy、previous3/next7、decode previous1/next2、NetLane normal5+current reserved1、priority 数值、dev.302 lane transaction、sourceCanvas、Reader geometry/presentation、dev.299 `current±2` static presentation continuity。

## 下一步证伪

下一份设备 Trace 首先比较常见 1/10/1 `pipelineReconcileTiming` 是否显著低于 dev.302 约 10.213ms 中位。若降低且 frame gap 同步下降，本根因得到设备闭环；若 reconcile 降低但 30–50ms gap仍在，则冻结此边界并继续剩余 UI-isolate/platform scheduling。
