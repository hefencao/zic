# dev.243 Streaming / cancel / rank 根因审计

## 设备证据

输入：`zic-debug-trace-2026-08-12T09-03-38.jsonl`，共5673条可解析事件。

- `taskFailed`共12次，其中11次decode错误均为`Bad state: native source is disposed`，覆盖reader-2/3/4/6；对应source均未sealed，sourceLength从0、262144、786432一直到4194304不等。另1次为独立rhttp network response-body错误。
- Trace仍有23次`downloadPreempted`，证明NetLane本身具备抢占能力；current=1000可抢占rank0 background，normal pressure也存在真实victim preemption。
- `demandDetached`共150次，其中大量detach发生在跨Reader generation/跳页边界。源码审计发现最后claim消失时active receiving迁移priority 0，而active pre-open/source-plan路径直接`net.cancel()`，形成绕过policy rank的第二生命周期。

## 源码根因

`DownloadSession.attachSynchronizedIngressProjection()`在late join时捕获revision/epoch/targetLength后整段replay。physical writer若在await期间增长，会再次进入循环并调用`projection.rebuild()`；`Ingress.rebuild()`固定先`reset()`，而`reset()`会dispose当前EncodedSource。late projection在registry中先被发布，decode可在replay中途观察到source，于是下一次追赶把仍在使用的source销毁。

网络侧`DownloadTransferOwner._removeClaim()`用`session.state == receiving`决定是否保留active task。这个状态不是network task已支付工作的owner：source-plan/open等待也已经占据NetLane active slot和transport capability。按DownloadState直接cancel既绕过统一rank，也可能让`_hasCancellingActive`暂时阻塞normal pressure preemption。

## 收口

- late replay改为unpublished staging；同epoch只append新artifact suffix，稳定fan-out后一次publish。
- active task最后claim归零统一priority 0，后续取消必须由NetLane rank/preemption或真实transport dispose产生；queued未admit仍可直接移除。
- 不调整dev.241 rank参数，不把source-disposed异常下放为decode retry policy。
