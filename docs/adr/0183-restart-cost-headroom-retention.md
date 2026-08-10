# ADR 0183：restart-cost 按安全剩余 rank 空间投影

## 状态

Accepted。替代 ADR 0182 中“时间最多+60、流量最多+40，固定最多+100”的 rank 投影方式；ADR 0182 的 ownership、事实来源、admission/retention 分层与 current-safe 原则继续有效。

## 问题

dev.201 真机 Trace 证明 restart-cost 事实能够进入 victim selection，但固定最多+100与 base priority 强耦合。一个不可恢复 full-body attempt 已投入约5.88秒、6.29MiB，逻辑 detach 后 base priority 降到 retained-background=0，最终 retention priority仅73，仍会比刚开始、无重做成本的640/660/680任务更早成为victim。成本事实存在，却因生命周期把base降为0而几乎失去经济意义。

## 决策

1. 时间与流量仍分别使用连续指数饱和事实：`timeCost=1-exp(-elapsed/5s)`，`trafficCost=1-exp(-bytes/4MiB)`。不判断网速。
2. 两者合成为0..1的成本分数：`costScore=0.60*timeCost+0.40*trafficCost`。60/40现在是时间/流量成本权重，不再是固定rank点数。
3. retention rank投影改为占据从当前base到current-safe ceiling的剩余空间：`retention=base+(ceiling-base)*costScore`。因此同样的高重做成本在base被生命周期降为0后仍然有实际保护价值。
4. `ceiling=highPriorityThreshold-preemptionThreshold`；当前Reader网络配置为1000-40=960。即使成本完全饱和，1000 current仍满足既有40点抢占margin。
5. base/admission/pending priority保持原值；restart cost仍只决定active victim选择，不让旧任务主动申请更多slot。
6. endpoint、HTTP版本、瞬时/平均吞吐、decode/playback与Trace派生字段仍不得进入公式。
7. 如果没有有限high-priority threshold的通用Lane实例，保留原有最多100点的兼容fallback；Reader的NetLane使用有限1000阈值，因此采用headroom投影。

## 后果

- 已投入大量不可恢复成本的retained-background任务可在victim比较中超过一个刚开始的普通低priority任务，而不是因base=0自动成为最便宜victim。
- 高成本780任务可逐渐接近960，transition可能等待或选择其它更便宜victim；1000 current始终可抢占。
- 不新增scheduler、bandwidth manager、Reader gate或endpoint能力状态。
