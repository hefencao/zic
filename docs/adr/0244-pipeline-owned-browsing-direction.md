# ADR 0244：浏览方向由 Pipeline 单一预测并定向 3/7 工作集

- Status: Accepted
- Date: 2026-08-13

## Context

dev.264/265围绕NetLane continuity hold增加了outer yield与near-two保护，但12:49 dev.265真机Trace与重新审查证明这些修复在补偿一个更上游的缺失：ZIC的`RoleResolver`把`forwardEncodedPages=7/backwardEncodedPages=3`永久解释为page index的`+7/-3`，`HeuristicPolicy`的far priority与`AnimatedPrefetchPolicy`的5/3/2/1也各自按index正负解释“前/后”。Pipeline没有浏览方向事实。

这会让实际向index递减方向连续阅读时，7页预算长期放在身后而3页预算放在前方；一旦在下游按当前角色/距离补救，又会出现slot fairness、near-two保护和窗口membership互相补丁化。若简单用一次page delta立即翻转7/3，则一次短反向会瞬间交换窗口两侧并造成四个边界页同时失去claim，同样会制造churn。

只读参考`vibevenera-master.zip`中的`ReadingDirectionPredictor`、`DynamicPreloadPolicy.offsetsFor`、`PipelineWindowPlanner`和`DownloadRanker`提供了更清晰的所有权：方向是Pipeline session状态；单次反向只成为candidate，连续反向/趋势证据才切换；jump不学习；window、frame target和rank都消费同一个`readDirection`。

## Decision

1. `PipelineController`拥有唯一`BrowsingDirectionPredictor`与`_readDirection`。Reader只提交`ReaderObs.currentIndex/interaction`，不得新增UI方向owner；NetLane不得感知浏览方向。
2. 初始方向保持page-index正向。稳定current变化才提供方向样本；`Interaction.scrubbing`、`Interaction.jumping`与abs(delta)>5不学习方向。单次反向只记录candidate，连续两次反向即可确认；历史样本按dwell权重与衰减趋势辅助判断。
3. `RoleResolver`的forward/backward从“index正负”改为“预测浏览方向正/负”：forward 7、backward 3以及decode 2/1的数量完全不变。单次短反向不翻转工作集；确认反向后才交换7/3两侧。
4. `HeuristicPolicy`的far/static rank与`AnimatedPrefetchPolicy`的5/3/2/1全部使用`readDistance=(pageIndex-currentIndex)*readDirection`。`next/next2/previous`由同一directional RoleWindow生成，禁止第二套index-sign方向解释。
5. dev.265跨层`protectFlowRetentionFromNormalYield`删除。near-two不再向TransferOwner/CancelToken/NetLane复制Reader物理距离。冻结5/3/2/1本身提供局部等级：next2为target3，因此DownloadJob只有在`!retainFlowResponse && !rangeSupported && flowTargetFrames<=2`时才把已满足no-Range continuity声明为yieldable；immediate previous虽target2但`retainFlowResponse=true`，仍不可yield。
6. dev.262的no-Range response continuity与dev.264的cooperative slot fairness保留，因为它们分别解决“无Range时主动断response会prefix replay”和“已满足outer hold可能占满5个slot”两个独立transport事实；但它们不再拥有方向/距离例外。
7. `policyDecision`记录`readDirection`，真机可直接重建方向确认点、窗口翻转和detach边界。

## Consequences

- 一页反向不会立即交换7/3，因此短暂回看不会一次使原前进侧多页失去claim。
- 持续反向经确认后7/3才翻转；此时离开新工作集的outer页可以撤销logical claim，但physical partial仍按既有authority保留。
- Pipeline重新成为方向、窗口、角色、rank与flow credit的唯一解释层；NetLane只处理已经声明的priority/yieldable事实。
- 删除dev.265 near-two跨层metadata，减少`DownloadDemand → TransferDemand → NetLane`重复局部性状态。
- previous3/next7、decode2/1、5/3/2/1、holder7/5/3/2、NetLane normal5+current reserved1均不改变。
