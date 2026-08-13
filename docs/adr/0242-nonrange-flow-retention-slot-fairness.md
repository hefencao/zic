# ADR 0242：non-Range flow continuity hold 必须向未获槽的正常 demand 协作让槽

- Status: Superseded
- Date: 2026-08-13

> dev.267由ADR 0245回滚本轮的下游slot/near或方向-cancel耦合；本文件仅保留历史根因与失败证据。

## Context

dev.262为避免服务器不支持Range时在3/7内发生真实full-body prefix replay，将`ByteResponse.rangeSupported == false`的consumer-paced response在正frame credit满足后继续保留在同一个physical task/response。11:45 dev.263真机Trace证明这个局部修复产生了新的slot-lifetime矛盾：已满足body target的no-Range response仍以active task占normal NetLane permit，而NetLane自dev.245/246起禁止normal priority主动取消receiving task。于是一个方向上已满足、只为continuity而活着的response可以长期占槽，另一方向尚未建立partial的previous2/previous3 demand即使一直存在也无法获得permit。

设备事实显示，下降阅读方向中page275/page274几乎到current才首次`downloadStarted`，后段page272/page271/page270也分别到current后约26ms/21ms/135ms才启动；反方向page279/page280可提前约18.9s/20.0s，page283/page284也提前约4.8s/5.8s，且page285–289均能在未成为current前建立连接。另有page102在8.007s进入`range-resume-unproven` pseudo-retention后，离开当前阅读区域仍持续占用task并缓慢增长partial，直到43.798s才被current destructive preemption终止。

这里必须区分“正在接收尚未满足的body work”和“body credit已经满足、仅为了避免未来prefix replay而保留response”。后者是可选continuity资源，不应拥有饿死另一个3/7 demand的权力。

## Decision

1. DownloadJob在正frame target与decoder playable floor均满足、且因`rangeSupported == false`继续保留response时，向同一个NetLane `CancelToken`报告flow-retention状态。
2. 只有`!retainFlowResponse && !rangeSupported`的已满足continuity hold标记为`yieldable`。immediate next/previous显式`retainFlowResponse`、current/transition target0、以及尚未满足body credit的active receiving均不可由该机制让槽。
3. 当normal NetLane/bucket真实满载且存在尚未获得slot的priority>0 normal pending demand时，NetLane可以选择最低semantic priority的yieldable continuity hold，请求一次cooperative flow yield。若bucket本身满载，victim必须来自同bucket。
4. cooperative yield不是normal destructive preemption：不得设置`CancelToken.cancelled`，不得生成`downloadPreempted`，不得提前释放permit。DownloadJob在既有consumer-paced flow gate中收到请求后记录`pseudo-yielded`与`yieldToPriority`，随后通过既有typed `DownloadFlowSuspended`退出；task真实完成后NetLane才pump并发出slot。
5. 同一时刻最多一个flow yield request处于in-flight，防止一次pending变化同时驱逐多个continuity hold。
6. role在yield执行前晋升为immediate adjacent或current时，既有flow metadata迁移必须撤销yieldability/request，从而优先保留高概率马上使用的同response连续性。
7. dev.262规则仍成立：没有slot pressure时，no-Range outer response不得仅因frame credit满足而主动关闭；Range-resumable非adjacent response仍可正常`pseudo-suspended`。

## Consequences

- 3/7需求窗口仍完整存在，且两个方向都能最终获得真实normal slot；不会通过提高previous优先级、增加连接数或改变窗口方向来掩盖资源生命周期错误。
- normal 640/660/780等工作仍不能取消一个尚未满足body work的active receiving；ADR 0226关于normal destructive preemption删除继续有效。
- 在5个normal slot确实有竞争时，某个no-Range outer页可能失去原response并在未来角色升高时发生prefix replay；这是固定slot容量与no-Range服务器能力之间不可消除的物理取舍，但只在真实未满足demand需要slot时发生，不再无条件切断。
- immediate next/previous warm response仍优先保留，因此快速一页往返的dev.260目标不回退。
