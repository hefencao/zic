# ADR 0233：decode ingress epoch authority 与 bounded consumer flow suspension

状态：Accepted

## 问题

dev.253后的02:27设备Trace没有`taskFailed/sourceDisabled`，但出现2次DecodeSession直接进入`failed`且没有对应task exception。page335在成为current后同一个physical download已从约8.36MiB低水位状态原地升为unlimited并继续增长到15.1MiB，随后完整seal/promote；DecodeSession却在source继续演化时提前failed，upload同步failed且页面无first frame。

DecodeSession此前同时持有physical DownloadSession与Reader-local DownloadIngressProjection：preflight用`download.epoch`检查projection source，异步decode也继续比较physical epoch。physical generation已经由DownloadIngressProjectionRegistry/LiveCoordinator source-watch投影到Reader ingress，再在DecodeSession重复读取physical epoch形成第二generation authority。该preflight还能通过`_setFailure(...); return snapshot`静默terminalize，LiveCoordinator随后却把source revision记为已消费。

同一Trace还有1800次`consumerPacing/pseudo-drain`。target=1的记录completedFrames中位38、最大122；周期性放行一个chunk虽然避免长hard-pause，却让远端动画最终持续越过1/2/3/5帧水位，预下载控制失去实际边界。

## 决策

1. DecodeSession不再持有physical DownloadSession。decode epoch唯一取自当前Reader-local ingress projection；source实例与projection epoch不一致先重读一次，仍处于generation交接则回到waitingSource，不产生terminal content failure。
2. 异步frame decode期间只比较当前ingress projection epoch；变化时旧work以cancelled生命周期退出。physical session/alias/generation变化继续只由Ingress registry与source-watch投影/失效。
3. ingress显式failure仍可成为decode failure，但必须抛给LiveCoordinator；LiveCoordinator若收到`failed/failure` snapshot同样转入现有failure诊断/recovery，绝不能先把source revision标记consumed。
4. `streamBackpressure`真实pause行为不变。`consumerPacing`达到frame credit后最多等待100ms同response升水位；仍blocked则抛typed `DownloadFlowSuspended`，DownloadJob flush已收bytes、取消response并调用`DownloadSession.pause(writer)`，不记录network failure。
5. DownloadTransferOwner记录physical id的`targetFrames + committedLength` flow suspension。相同target/partial仍被demand时视为该speculative credit已满足，不自动重开；flow target改变（尤其current/transition=0）或partial generation变化后才重新调度并从authoritative partial resume。
6. 3/7 demand、5/3/2/1 frame credit、NetLane 5+current-reserved1、provider/partial/progress identity均不改变。

## 后果

Decode不再有physical-session epoch与Reader-source epoch双重权威；source generation换代只通过projection生命周期传播。unsupported upstream pause也不再用无限pseudo-drain伪装成帧水位，远端网络任务在达到当前credit后真正进入quiescent partial状态；代价是再次提高credit时可能需要新的Range/resume attempt，这是transport能力不足的显式成本，而不是隐性持续流量。
