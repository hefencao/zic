# ADR 0239：相邻页 warm response 与 bounded flow credit 分离
> dev.268：ADR 0246 supersede `retainFlowResponse/pseudo-retained` 实现；相邻页“不得因水位主动重开response”的目标由统一response parking满足。

状态：Accepted

## 问题

dev.259 让 opaque WebP 在 runtime sniff 后真正进入5/3/2/1 bounded flow。09:00真机Trace随即暴露dev.254遗留的直接回归：page99作为next1时在491,520 bytes达到target5，于8.840s由`consumerPacing`主动`pseudo-suspended`并结束response；约99ms后页面成为current，8.944s只能从同一partial重新`downloadStarted`。该重开不是NetLane 5路容量驱逐，也不是partial失效，而是把“body credit已满足”错误等同于“response必须关闭”。

连接容量、response存活与partial retention是三种独立资源。3/7可以保留11个physical partial，但normal NetLane同时只执行5个body task；是否值得保留一个已达到水位的response，应由页面近期前景概率决定，而不能由partial水位本身决定。

## 决策

1. `DownloadDemand`新增`retainFlowResponse`调度元数据，并沿`TransferDemand → NetLane → CancelToken`原位迁移；它不属于transport capability、partial content fact或animation truth。
2. 只有immediate `PageRole.next`与`PageRole.previous`设置该标记。current/transition仍以target0 unlimited执行；next2/near/far不保留warm response。
3. 对`consumerPacing`，当structural frame target与decoder playable-prefix floor均满足：
   - `retainFlowResponse=true`时不抛`DownloadFlowSuspended`，保持同一个response/task，记录一次`pseudo-retained`，随后最多每100ms允许一个body chunk；
   - target升为0时由同一CancelToken唤醒并记录`pseudo-resumed`，不得产生第二个`downloadStarted`；
   - retain标记因角色远离而撤销时，同一blocked response在下一轮立即进入既有`pseudo-suspended`路径，pause writer并保留authoritative partial。
4. warm response继续占用现有NetLane active/bucket slot；不建立隐藏第6+ normal connection，不实现半成品paused-connection pool。
5. physical frame proof/playable floor、3/7、5/3/2/1、normal5+current reserved1、provider/partial/source/decode ownership全部保持不变。

## 后果

一页前后的高概率切换可复用同一consumer-paced response，避免“next1刚达到5帧就关连接、100ms后current又重开”。与此同时只有相邻两侧允许低速warm retention，远端仍会在达到水位后释放response，因此有限5路仍能轮转建立3/7 partial，而不会恢复全窗口无限pseudo-drain。
