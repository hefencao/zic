# dev.189 Venera Plan Churn 根因审计

## 输入

- 代码基线：`zic_v0.31.0-dev.188_venera-dynamic-priority-observation.zip`
- dev.187设备trace：`zic-debug-trace-2026-08-09T11-04-46.jsonl`
- dev.188设备trace：`zic-debug-trace-2026-08-09T11-42-04.jsonl`

## 对照统计

只统计 `artifactSource(source=origin)` 且含 dev.186 stage diagnostics 的样本：

| 指标 | dev.187（21） | dev.188（23） |
|---|---:|---:|
| request-plan median | 3.467s | 3.989s |
| request-plan p90 | 5.421s | 9.353s |
| request-plan max | 6.935s | 12.330s |
| host-open median | 0.331s | 0.399s |
| host-open p90 | 2.063s | 1.460s |
| host-open max | 2.502s | 2.321s |

因此“临时网络整体变慢”不足以解释dev.188退化：真正最终图片host-open没有同步拉长，request-plan尾部却显著扩张。

## 调度证据

11:42 trace中同一个transition任务可在约0.8s内经历 `780→900→780→900→1000`。dev.188的waiter subscription对每一次priority变化重新调用preemption判断，active invocation降级也会反向重新判断waiting previous。由于cancel不可逆，角色抖动会造成plan work废弃，而角色稍后又可能反转。

外层NetLane仍正常：首批1000/820/800/780/760几乎同时取得5个normal slots；问题位于后续Venera单invocation request-plan阶段。一个最终priority1000样本 `sourceRequestPlanMicros=12.330s` 而 `sourceHostOpenMicros=0.703s`，另一个current为8.362s plan +0.772s host-open。

## 修复边界

- 保留首次previous=780 pressure；这是dev.186设备证据支持的normal-slot/request-plan交棒。
- 保留waiter实时priority用于permit transfer排序。
- 动态preemption仅允许waiter真正跨入current=1000时触发。
- active demotion与780↔900不触发cancel。
- 不增加Venera并发，不改变Reader固定参数。

## 新观测

为下一轮避免继续猜测，dev.189把聚合 `sourceRequestPlanMicros`拆出gate wait、runtime invocation、JS hook与hook内部bridge network四项。它们全部是read-only diagnostics，不成为新policy owner。
