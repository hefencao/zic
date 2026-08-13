# ADR 0243：近二页 no-Range continuity 不得为 outer normal fairness 主动让槽

- Status: Superseded by ADR 0244
- Date: 2026-08-13

> dev.266由ADR 0244以Pipeline-owned browsing direction与flow-credit locality取代本ADR的跨层`protectFlowRetentionFromNormalYield`实现；本文件仅保留dev.265历史根因。

## Context

dev.264通过cooperative flow yield修复了no-Range outer continuity hold长期占据5个normal NetLane slot、导致另一方向3/7 demand整体饥饿的问题。但12:25 dev.264真机Trace证明“所有non-adjacent satisfied hold都可yield”过宽：current=270时page272仍为next2/target3，却在8.167s被`pseudo-yielded`；current=267时page269仍为next2/priority800/target3，却在13.894s为了priority640的page264(previous3)让槽，随后page264于13.911s获得`downloadStarted`。

Trace中`downloadPreempted=0`且没有cancel事件，所以这里不是destructive preemption回归；问题是dev.264把“只隔一个页面的next2/previous2”错误归入了可牺牲outer continuity。近二页与immediate adjacent虽然对response保留强度不同，但都属于高概率马上进入foreground的局部工作集。

同时不能简单把next2/previous2设置为`retainFlowResponse=true`：该位会让Range-capable response也保持live connection，从而把“禁止normal fairness yield”错误升级成“无论transport capability都不允许正常Range suspension”。

## Decision

1. Reader heuristic新增独立调度语义`protectFlowRetentionFromNormalYield`，仅按当前页物理距离投影：`abs(pageIndex-currentIndex) <= 2`为true。它与`retainFlowResponse`、flow target、Range capability互相独立。
2. `retainFlowResponse`继续只对immediate next/previous为true；因此Range-capable next2/previous2在满足body/playable credit后仍可按既有规则`pseudo-suspended`，不会因near-two保护无条件占连接。
3. `protectFlowRetentionFromNormalYield`沿`DownloadDemand → TransferDemand → DownloadTransferOwner → NetLane pending/active → CancelToken`迁移。physical identity有多个consumer claim时保护取OR，避免一个仍处near-two的consumer被另一较远claim取消保护。
4. DownloadJob仍只报告“该no-Range satisfied response从body事实看可作为optional continuity”；CancelToken在`markFlowRetention()`处统一应用near-two保护。被保护token即使收到`yieldable=true`报告也保持`flowRetentionYieldable=false`，NetLane不能把它选为normal-pressure victim。
5. role从outer进入distance<=2时，metadata migration必须立即撤销尚未执行的flow-yield request；从distance<=2离开到outer时撤销保护，DownloadJob下一次flow评估可重新声明yieldable。
6. 最后一个logical Reader claim消失后，task可以保留旧positive flow target/authoritative partial，但`retainFlowResponse`与near-two保护都必须清除；rank0 retained task不得永久携带已经不存在的Reader局部性。
7. dev.264 outer fairness继续成立：distance>=3、no-Range、positive credit与playable floor已满足的hold仍可在真实normal slot pressure时cooperative `pseudo-yielded`。该路径仍不cancel、不记录`downloadPreempted`、不提前释放permit。

## Consequences

- “只隔一页”的next2/previous2不会再为了previous3/next3+等outer demand主动断掉no-Range response。
- 3/7窗口没有缩小；outer需求仍有dev.264的slot-fairness出口。稳定current周围最多四个非current distance<=2 identity拥有该保护，因此该机制不会把整个3/7改成永久live-response窗口。
- 不新增连接、不修改5/3/2/1、不修改Reader方向priority，也不恢复normal destructive preemption。
