# ADR 0235：physical frame-prefix proof 与 flow target 解耦

状态：Accepted

## 问题

dev.254/255 的 consumer-paced suspension 用`targetFrames + committedLength`记“当前flow target已满足”。04:31真机Trace已无preempt/cancelled failure，但44次正target `downloadStarted`中有22次可以由既有`flow-satisfied.completedFrames`直接判定无需重开：一个chunk常越过目标，例如target=1时实际已有22/26帧，随后target=2/5仍因精确target不相等而open；demand detach后旧suspension也被清除。

这把Pipeline policy target错误写进physical partial事实。`1/2/3/5`只是当前角色希望的最低帧数；partial中已经存在多少完整ANMF帧才是可复用的内容事实。

## 决策

1. `DownloadTransferOwner`以`_FlowFrameProof`保存physical prefix已证明的`completedFrames`与证明时prefix length，并绑定实际`DownloadSession`对象generation；不保存触发proof的`targetFrames`。
2. 任意未来正`flowTargetFrames <= proof.completedFrames`，且当前session仍是同一generation、committedLength未低于proof prefix时，视为该flow demand已经满足，不创建network task。
3. target=0表示foreground unlimited，永远不能被bounded proof满足；target高于proof才允许从authoritative partial继续attempt。
4. role target变化、claim detach/re-add不使proof失效。partial append保留proof；真实truncate/reset、physical session generation更换、promotion/dispose使proof失效或失去意义。
5. 新的suspension只提升proof，不得因较低completedFrames降级已有proof；`flow-satisfied`增加`satisfiedThroughFrames`诊断。
6. 不改变3/7、5/3/2/1水位、NetLane 5+1、preemption、partial validity或transport capability。

## 后果

前后页和快速角色交换仍可改变priority/target，但不能把已经存在于partial中的帧重新解释成“尚未预下载”。网络attempt只为真正缺少的帧或foreground unlimited而启动。
