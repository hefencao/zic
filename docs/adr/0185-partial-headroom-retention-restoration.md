# ADR 0185：部分恢复 restart-cost headroom retention

## 状态

Accepted，supersede ADR 0184 对 dev.202 headroom 的全量撤回；ADR 0182/0183 的历史证据继续保留。

## 背景

dev.202 将 restart-cost score 投影到 `base -> current-safe ceiling` 的全部剩余空间。11:26 真机体感较 dev.201 退化，但随后审计确认 6.84 秒最坏首帧主要由 current 自己的 Venera source-plan / host-open 冷路径造成，不能把该长尾归因于 retention。dev.203 因此把 headroom 全部撤回到 bounded +100，回滚幅度过大。

## 决策

1. admission/pending priority继续完全由既有 scheduler role拥有；restart cost只参与 active victim selection。
2. 时间成本仍使用5秒尺度，流量成本仍使用4MiB尺度，`costScore = 0.6*timeCost + 0.4*trafficCost`，均连续、单调、饱和。
3. 同时计算：dev.201 bounded retention=`base + 100*costScore`（受current-safe ceiling限制）；dev.202 headroom retention=`base + (currentSafeCeiling-base)*costScore`。
4. dev.204最终 retention 取两者之间固定插值：`bounded + 2/3 * (headroom - bounded)`。因此相对dev.202只回滚约1/3，而不是dev.203的全量回滚。
5. current-safe ceiling继续为`highPriorityThreshold-preemptionThreshold`；当前配置1000/40下最大retention不得超过960，current始终可抢占。
6. restart-cost事实仍只来自取消后必须重新支付的不可恢复attempt；endpoint、网速、trace字段、decode/playback状态不得进入公式。

## 非目标

不改变network=5、role priority、handoff、Range/defer admission，也不让旧任务因历史投入主动获取新slot。
