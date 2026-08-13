# dev.256 根因审计：精确 flow target 导致重复 transport open

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.255_scheduler-cancel-partial-lifecycle.zip`。
- 真机Trace：`zic-debug-trace-2026-08-13T04-31-24.jsonl`，3353条事件。

## 事实

- `downloadPreempted=0`、download failed=0、`Failure(cancelled)=0`、task/source/decode failure=0；dev.255的scheduler-cancel/partial生命周期修复成立，本轮不应继续调preemption。
- `downloadStarted=61`，其中44次为正`flowTargetFrames` speculative attempt；`flow-satisfied=47`。
- 按同一identity最近一次`flow-satisfied`回放，只要committedLength相同且`completedFrames >= 后续target`，44次正target start中有22次已经满足，不需要open。
- 代表例：identity `<1ad730636a71bd1f,178>` target1 suspension实际completedFrames=22、committedLength=2392064，约1.59s后target2仍以同长度重开；`<5600dca52c4c386e,178>` target1实际26帧，约3.46s后target2重开；另一个partial target5实际7帧后99ms改target3也重开。

## 根因

`_FlowSuspension`保存的是触发suspension的精确policy target，`_ensureDownloadTask/_idleFor/_upsertClaim`要求新target与旧target完全相等；claim detach还删除该状态。由此把“当前角色要求几帧”误当成“partial里已经有什么”的内容事实。

## 所有权

- `1/2/3/5/0` frame target：Pipeline policy。
- physical DownloadSession / authoritative partial：composition transfer ownership。
- partial prefix中已证明的完整动画帧数：physical transfer content fact，必须独立于某一role target与consumer claim lifetime。

## 决策

将target-specific suspension memory改为generation-aware monotonic frame-prefix proof；正target不高于proof时直接quiescent，target=0或更高target才resume。窗口、rank、并发与partial状态不变。
