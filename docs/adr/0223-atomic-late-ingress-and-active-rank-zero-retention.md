# ADR 0223：Atomic late ingress publication 与 active rank-zero retention

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.243

## 背景

09:03真机Trace确认dev.242已经让verified-equivalent同图共享physical partial/progress，但流式播放出现新的`Bad state: native source is disposed`。源码对照显示late Reader在已有committed prefix上异步`synchronized replay`；physical writer若在replay期间继续append，旧实现会整段重新`rebuild()`，而`Ingress.rebuild()`先`reset()`并dispose旧EncodedSource。decode可在第一次replay中途观察该source，因此后续追赶会销毁一个仍被cursor使用的source。

同一Trace还显示跨Reader短暂demand gap会触发大量detach。`DownloadTransferOwner`旧实现只对`DownloadState.receiving`的active task降priority 0，source-plan/open阶段的active task在最后claim消失时直接`net.cancel()`。这既绕过dev.241统一rank，也会制造cancelling-active窗口，使普通pressure arbitration必须等待旧task物理退出。

## 决策

1. late synchronized ingress replay在authoritative boundary稳定前保持source unpublished。Reader decode可看到projection但只能进入waitingSource，不能绑定中间replay source。
2. 第一次late replay允许从0构建；若physical writer只在同一SourceEpoch继续增长，后续追赶只读取`artifact.readChunks(start: projection.length, endExclusive: committedLength)`并append suffix，不得重新reset/source-dispose。epoch变化、resident immutable authority或不兼容projection才允许在未发布阶段完整rebuild。
3. verified committed boundary与physical fan-out insertion之间不得有await；projection先加入live fan-out，再一次性publish source。后续physical append直接进入同一source实例。
4. 最后logical claim消失时，任何已经active/admitted的network task不论receiving/source-plan/open状态都迁移到priority 0。是否取消由NetLane统一rank/preemption决定。
5. 尚未admit的queued task没有已支付transport工作，可直接`cancelQueued`。consumer-bound transport owner真实dispose仍是lifecycle硬边界，不折算成rank。

## 否决

- 不在decode层捕获`native source is disposed`后循环重试；该异常是owner生命周期错误。
- 不把late replay锁住physical writer；Reader-local重放不得反压真实网络writer。
- 不恢复receiving/pre-open两套detach策略，也不在Reader手工cancel旧连接。
- 不修改dev.241 policy rank数值来掩盖直接cancel旁路。
