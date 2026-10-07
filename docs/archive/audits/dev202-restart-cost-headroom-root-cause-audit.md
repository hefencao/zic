# dev.202：restart-cost retention 低base失真根因审计

## 基线与设备证据

唯一代码基线：`zic_v0.31.0-dev.201_restart-cost-retention-victim-ranking.zip`。输入Trace：`zic-debug-trace-2026-08-10T10-55-37.jsonl`。

Trace约57.3秒，包含7723个事件、136次`downloadPreempted`。只有2次被取消victim的restart-cost bonus非0，说明dev.201信号已接通但实际保护范围很弱。最关键样本：一个full-body catch-up在取消时已投入5,879,524µs、6,292,600 bytes；demand detach已把base priority降到0，dev.201固定+100模型只得到retention priority=73，incoming=800仍直接取消。

本轮origin body共约141.27MiB；`resume*`记录的duplicate prefix约13.64MiB（约9.2%）。合法strong-validator Range有10次，均为0 duplicate；重复成本仍集中在服务器忽略Range后的full-body路径。

同时观察到独立的首帧尾延迟：17次first-frame中位约80ms，但5次超过500ms，最大约2.86s。41条origin请求中request-plan cache hit=12、miss=29；hit plan中位约0.015ms，miss中位约1.41s。该问题属于Venera request-plan冷路径，不与本轮NetLane retention公式混改。

## 根因

dev.201使用`retentionPriority=basePriority+fixedSaturatingBonus`，bonus理论上最多100。它能保护780对抗稍高rank，但无法表达“生命周期把base降到0后，已经付出的6MiB/数秒重做成本仍然存在”。这不是需要把+100改成更大的常数，而是投影空间选错：成本应该决定占据多少`base→current-safe ceiling`的保护空间。

## dev.202 方案

- 时间5s、流量4MiB尺度保持；0.60/0.40改为成本权重。
- 合成`costScore∈[0,1]`后，用`base+(ceiling-base)*costScore`得到victim retention rank。
- 真实5.88s/6.29MiB、base=0样本的模型rank约从73提升到703；它仍可被1000 current抢占，但在存在无成本640/660/680 victim时不再自动成为最便宜选择。
- 10s/8MiB、base=780约投影到936；900 transition不再无条件牺牲它，1000 current仍保留40点margin。
- 不扩大restart-cost事实来源，不把普通可resume工作或网速纳入模型。

## 待真机验证

1. `downloadPreempted`中高成本base=0 victim是否明显减少；如果被800取消，应确认没有更便宜candidate，而不是公式再次失真。
2. 1000 current的physical preemption/startup不能退化。
3. full-body attempt completion率与重复流量应改善，不能出现5个高成本旧任务长期占满normal slots导致transition普遍饥饿。
4. request-plan miss首帧尾延迟作为独立后续线继续分析。
