# ADR 0224：Admitted provider stability 与 physical transport cursor

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.244
- Supersedes ADR 0221 中“provider exact replacement由policy rank决定”的部分；NetLane对physical task slot/preemption的统一rank、restart-cost retention与`TransferRankPolicy` costly catch-up admission继续有效。

## 背景

09:47真机Trace中verified-equivalent acquire仍稳定join既有physical owner，但可见进度在切页回来后长时间不增长。Trace汇总得到55,743,710 bytes `duplicatePrefixBytes`：44,741,284 bytes来自完成的full-body prefix catch-up，10,412,602 bytes来自catch-up中途被取消后的白读。两次`active-provider-handoff`都在同一physical partial上仅因preferred exact/rank变化取消旧provider，其中一条已支付5.59MiB restart cost后仍重开另一个等价provider。

dev.242以后direct verified-equivalent exact requests已经共享同一个physical byte authority；current/previous/version变化只需要改变这个physical task的scheduler rank，不需要为了logical exact URI重新建立网络request。provider exact URI仍决定validator/request语义，但一旦attempt已admit，它应属于该task lifetime，直到完成、失败或真实transport capability失效。

现有Reader progress只投影`networkStartLength`与`committedLength`，无法显示Range→200时transport正在重读0..partial的事实，导致“已有partial不动”无法区分连接等待、prefix replay、取消重开和真实新增字节。

## 决策

1. 删除`DownloadTransferOwner._handoffActiveProviderIfNeeded`及其claim-change调用。logical exact/provider preference和priority变化只迁移唯一physical NetLane task的priority，不取消一个已经admit的verified-equivalent provider attempt。
2. provider consumer真实dispose仍是硬lifecycle边界：consumer-bound transport必须cancel+idle；显式task-retained transport可继续。attempt失败/结束后若仍有demand，下一task自然从当时preferred claim选择provider exact。
3. `DownloadSession`新增transient `networkAttemptSequence/networkAttemptActive/networkCursorLength`。它只描述当前transport实际消费到的绝对字节位置，不参与resume、durable identity、alias、artifact或rank。
4. `DownloadJob`在最终response确定后以`response.rangeStart`开始network cursor；validatorless overlap、full-body prefix replay、普通206/200 body和resident immutable stream都推进同一个cursor。新attempt可以从更小位置重新开始，因此UI可以直接看见重读，而authoritative `committedLength`保持独立。
5. Pipeline只从resolved physical session同时投影authoritative partial和transient transport cursor，并按VibeVenera Reader progress publisher的0.7/0.3速度平滑计算当前transport speed。
6. Reader显示双层：authoritative/max partial为theme secondary直线；当前transport为波浪线，其颜色使用实际VibeVenera的对数速度映射（128KiB/s基准、8MiB/s上限，红→amber→绿）。波浪在full-body replay时可落后于直线并追赶，attempt重开时可回退；这属于观测，不改变任何下载策略。

## 不变量

- physical partial/writer只有`DownloadSession`一个authority。
- network cursor不得持久化，也不得用来判断resume continuity。
- provider稳定不允许越过consumer-bound transport真实dispose。
- NetLane仍是唯一slot/preemption owner；删除provider takeover不是禁用normal task preemption。
- UI不得根据两条进度自行cancel、retry或改变rank。
