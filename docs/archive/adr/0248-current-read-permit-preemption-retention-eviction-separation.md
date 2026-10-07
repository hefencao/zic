# ADR 0248：current body-read preemption 与 inactive response eviction 事务解耦

## 状态
Accepted in `0.31.0-dev.270`。

## 背景

dev.268/269 已把 live response、body-read permit、demanded flow pause、inactive response retention 分开，但 inactive retention 超限仍通过 `cancelForPreemption(TaskPreemptionSnapshot)` 销毁 parked response。因此 `_hasPreemptionInFlight` 无法区分“正在回收一个不占 read permit 的后台 response”与“正在为 current 回收 body-read permit”。00:22 真机 Trace 中 11 次 `downloadPreempted` 全是 `inactive-response-retention-eviction`，没有真实 `high-priority` preemption；这暴露出 retention cleanup 仍能占用 current-preemption single-flight 的反向耦合。

## 决策

1. `TaskPreemptionSnapshot/cancelForPreemption` 只属于 priority/body-read permit preemption；victim 必须是实际持有 read permit 的 running task。
2. inactive live-response retention 超限改用独立 `TaskRetentionEvictionSnapshot/cancelForRetentionEviction`，并由独立 single-flight 状态串行化。
3. body-read preemption 可以与一个尚未物理退出的 inactive retention eviction 并行；反向不允许：current preemption 正在进行时，后台 retention cleanup 暂停发起新的 eviction。
4. 一个已存在 live response 的 current-ranked read-permit reacquire 比“新建另一个 blocked high-priority pending task”的 destructive admission 更便宜、更接近当前展示，因此 blocked arbitration 先处理 live-response resume，再处理 pending admission。
5. Trace 中真实 priority preemption 保持 `downloadPreempted(preemptionReason=high-priority)`；inactive retention destruction 改为 `downloadEvicted(evictionReason=inactive-response-retention-eviction)`。
6. 不改变 previous3/next7、动画 5/3/2/1、decode 2/1、normal5 + current reserved1、restart-cost victim ranking 或 current threshold=1000。

## 后果

current 抢占权重新只围绕 body-read capacity；response retention cleanup 不再能锁死它。Trace 也可直接区分 foreground preemption 与后台 eviction。该 ADR 不赋予 Reader、DownloadJob 或 retention owner 第二套 priority policy。
