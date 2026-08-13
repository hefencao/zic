# dev.265 根因审计：dev.264 outer fairness 误伤近二页 continuity

## 12:25 dev.264 真机设备事实

本Trace没有`downloadPreempted`或cancel事件；用户看到的“cancel”对应`transport-flow-control / pseudo-yielded`后当前response真实退出。问题不是cooperative yield被升级成destructive cancellation，而是victim资格过宽。

最直接的两组样本：

- current=270时，page272仍为next2，flow target=3。它在8.167252s以`completedFrames=3 / committedLength=417499 / responseRangeSupported=false`记录`pseudo-yielded`，`yieldToPriority=740`。next2因此仅隔一个页面仍被normal fairness回收。
- current=267、target=268时，policy明确page269为next2/target3；page269在13.893535s以`committedLength=1505260`记录`pseudo-yielded`，`yieldToPriority=640`。17.56ms后page264以priority640首次`downloadStarted`。也就是更远的previous3需求直接通过dev.264 fairness牺牲了priority800的next2 live response。

Trace中page270在current=268时也出现同型next2/target3 yield，说明不是单一identity或网络异常。

## 根因

dev.264只用`retainFlowResponse`区分“不可yield immediate adjacent”和“可yield non-adjacent”。但`retainFlowResponse`原本只回答“是否值得强制保持同response”，不是完整的Reader局部性等级。next2/previous2故意没有该bit，以便Range-capable transport满足credit后能安全suspend；dev.264却据此把它们与distance>=3 outer hold等价，导致两个原本独立的问题被混成一个布尔条件。

## Issue / authoritative owner / rejected fixes

- Issue：normal slot fairness缺少Reader近二页保护语义，next2/previous2被当成outer continuity victim。
- authoritative owner：Reader heuristic只投影“distance<=2是否受normal-yield保护”；DownloadJob继续只拥有transport capability/body proof；NetLane仍唯一决定何时真实需要回收slot。
- rejected：把next2/previous2直接设`retainFlowResponse=true`；提高next2/previous2 priority；禁止所有low-priority incoming yield high-priority hold；缩3/7；增加normal连接；恢复normal destructive preemption。前两者会污染Range suspension/策略权重，第三项会重新制造dev.264的方向性饥饿。

## dev.265 修改

- 新增`protectFlowRetentionFromNormalYield`，仅distance<=2为true，并完整贯穿DownloadDemand/TransferDemand/NetLane metadata生命周期。
- CancelToken在`markFlowRetention`统一把`yieldable && !protect`作为effective yieldability；DownloadJob无需重新持有Reader role。
- role migration原位更新保护；保护变true时清除尚未执行的yield request。最后一个claim消失时清除near/warm保护但保留原flow target，避免全量drain。
- Trace在`downloadStarted`记录`protectFlowRetentionFromNormalYield`，`pseudo-retained`记录`retentionProtectedFromNormalYield`，下一轮可直接确认next2/previous2的保护是否生效。
- 冻结previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2与NetLane5+1。
