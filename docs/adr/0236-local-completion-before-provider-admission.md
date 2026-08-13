# ADR 0236：local completion 必须先于 provider transport admission

状态：Accepted

## 问题

04:58真机Trace确认dev.256 frame-prefix proof已经闭环：没有proof可满足的正target重复open，也没有preempt/cancelled/download failure。但有3个physical identity此前已`artifactPromoted`，在后续新physical generation中经`prepareDownload`恢复完整本地artifact后仍记录`downloadStarted`；三次开始时`committedLength`分别为16,005,312、13,452,574、9,775,218 bytes，之后都没有新的`sourceRead/bytesCommitted/receiving`。

根因是`DownloadTransferOwner._runDownload`把provider transport选择/lease与`downloadStarted`放在local prepare完成事实之前；而真正的`DownloadJob`直到稍后才检查`DownloadState.promoted`并立即返回。于是本地完成被错误投影为network lifecycle，并短暂进入provider/NetLane执行边界。

## 决策

1. 抽取`DownloadJob.completeWithoutTransport`作为唯一local-completion primitive：promoted直接完成；committedLength等于known totalLength时在无transport条件下seal/promote；否则返回未完成。
2. `DownloadTransferOwner`在`prepareDownload`完成后先调用该primitive。若已本地完成，记录`artifactSource stage=transfer-admission action=local-completion-short-circuit`并返回。
3. provider `retainedTransportFor/transportFor` lookup、`_ActiveProviderLease`创建及`downloadStarted`必须发生在local-completion检查之后。`downloadStarted`只表示仍需要真实provider transport attempt。
4. prepare期间logical claim可能变化，因此local prepare结束后、provider lease建立前必须重新解析当前preferred claim；不得把prepare前consumer/provider引用跨该异步边界固定下来。
5. 本轮不移动async prepare本身到NetLane之外，也不修改3/7、5/3/2/1、frame-prefix proof、NetLane/preemption或partial/source/decode ownership。是否需要进一步把local prepare从network permit前移，必须由后续设备source-wait证据单独决定。

## 后果

本地promoted/完整partial恢复不再伪造`downloadStarted`或provider transport lease；provider telemetry重新表示真实网络attempt。physical local preparation与provider request lifetime获得明确边界，同时不新增第二scheduler或preparation registry。
