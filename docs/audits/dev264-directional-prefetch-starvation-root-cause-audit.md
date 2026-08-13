# dev.264 根因审计：no-Range continuity hold 导致单向3/7预下载饥饿

## 11:45 dev.263 真机设备事实

本Trace的页面移动分成清晰的两个方向，下载启动时序明显不对称：

- 从page278向更小页码移动时：page277以previous priority780提前约2.644s启动，page276只提前约0.683s；page275在成为current后约28.9ms才首次启动，page274在成为current后约123.6ms才首次启动。
- 后段继续向page270移动：page273曾以priority640提前约3.744s拿到一次slot，但page272/page271/page270分别直到成为current后约26.2ms/20.9ms/135.0ms才首次`downloadStarted`。
- 相反方向预下载正常：page279/page280分别在成为current前约18.907s/20.048s已启动；page283/page284也提前约4.813s/5.831s；page285–289均在从未成为current的情况下获得normal连接。
- 因此不是previous3/next7 demand生成失败，也不是目标页URL/源整体失败；问题发生在normal NetLane slot admission。

Trace同时给出dev.262 side effect的直接样本：

- page102在8.007s达到target2后记录`pseudo-retained / responseRangeSupported=false / retentionReason=range-resume-unproven`，committedLength约303,680 bytes。
- 之后阅读位置已经多次大幅迁移，该physical attempt仍继续低速消费body；到43.798s被current preemption时committedLength已约810,300 bytes。
- 当前阅读区域内也可见page278在14.317s以`range-resume-unproven`进入pseudo-retention；这些hold已经满足自己的frame credit，却仍占normal active slot。

## 根因

dev.262正确移除了“no-Range + frame credit满足 => DownloadJob自行关response”的第二终止owner，但把“不要主动关response”实现成了没有slot-fairness出口的active continuity hold。与此同时ADR 0226已经删除normal destructive preemption，所以一个已满足、非adjacent、仅为了未来避免prefix replay而保留的response，与一个真正仍需要首次建立partial的normal demand在NetLane看来都只是active-vs-pending，后者永远不能取得slot。

固定的next侧priority更高（next=820、next2=800、distance next从760向下；previous=780、previous2/3为660/640）使该生命周期错误表现为方向性：向pageIndex减小方向连续阅读时，身后的高索引页落在next侧并更容易占满active slots，前方previous2/previous3被饿死；反方向则恰好受益。

## Issue / authoritative owner / rejected fixes

- Issue：flow credit已经满足的optional no-Range continuity hold缺少向真正unsatisfied normal demand让出有限NetLane permit的机制。
- authoritative owner：DownloadJob只报告“当前response已处于可选continuity retention”事实；是否需要回收normal slot仍唯一属于NetLane。
- rejected：提高previous priority、动态翻转3/7窗口、增加normal连接数、恢复normal destructive cancellation、重新改回所有no-Range正target立即pseudo-suspend、让Reader/UI决定哪个方向应该抢网络。

## dev.264 修改

- `CancelToken`新增`flowRetentionYieldable`与`flowYieldRequestedByPriority`，仅作为同一NetLane task的调度状态。
- no-Range、non-adjacent、已满足flow credit的response标记yieldable；显式adjacent warm retention保持non-yieldable。
- normal pending在无slot时可让NetLane请求一个最低priority yieldable hold协作退出；不cancel、不生成preemption snapshot，permit直到原task真实退出才释放。
- DownloadJob收到请求后记录`pseudo-yielded / retentionReason=netlane-unsatisfied-demand / yieldToPriority`，复用`DownloadFlowSuspended`让TransferOwner保存physical frame proof与authoritative partial。
- 新回归分别覆盖：yieldable hold可给640 normal demand让槽且token未cancel；adjacent warm hold不可被该normal pressure回收；DownloadJob cooperative yield保留partial且无`pseudo-suspended`。
- 3/7、5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane normal5+current reserved1全部不变。
