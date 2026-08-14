# dev.270 current preemption authority audit

## 设备证据

`zic-debug-trace-2026-08-14T00-22-58.jsonl` 共观察到 11 个 `downloadPreempted`，`preemptionReason` 全部为 `inactive-response-retention-eviction`，没有 `high-priority` current preemption。Trace 同时证明 dev.269 的 demanded/inactive parked 统计与 response parking 已在工作，因此优先审查新资源边界，而不是提高 current priority。

## 根因

NetLane 的 inactive parked response bound 仍调用 `cancelForPreemption`，使一个**已经释放 body-read permit**的 retention victim 也持有 `preemptionSnapshot`。`_hasPreemptionInFlight` 随后被 current pending 与 current parked-response resume 共用；只要后台 eviction 尚未退出，current destructive body-read preemption 就被抑制。retention capacity 与 body-read capacity 因同一事务锁重新耦合。

## 修复

- 将 inactive retention destruction 移到独立 `TaskRetentionEvictionSnapshot`；
- body-read 与 retention eviction 各自 single-flight，且 current preemption 优先；
- blocked current live-response reacquire 先于 blocked high-priority pending destructive admission；
- telemetry 将后台 retention destruction 改为 `downloadEvicted`，`downloadPreempted` 恢复为真实 priority preemption 专用事件；
- 新增回归：即使 inactive eviction 正在等待物理退出，current parked response 在 reserved headroom 已占用时仍可 preempt 一个低优先级 read-permit holder 并重新取得 permit。

## 非修复项

没有提高 1000 priority、没有扩大 5+1、没有降低 preemption threshold、没有缩小 3/7，也没有取消 restart-cost protection。
