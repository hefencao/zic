# dev.184 Current / Previous Receiving-State 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.183_current-bootstrap-execution-venera-physical-preemption.zip`
- 设备 trace：`zic-debug-trace-2026-08-09T08-58-13.jsonl`
- 只读参考：文件库 `vibevenera-master.zip`（当前库实例名 `vibevenera-master(4).zip`）

## Trace 结论

本轮先排除了“previous demand没有生成”。在 revision 22，current=16 时，相邻后向 identity `identity:<70ec2f32fc247e52,177>` 从 priority 660 提升为 previous 780，但当时 `active=false`；直到约 3.004 秒后才 `downloadStarted(priority=780)`。同一轮新的 current 已能用第6个 bounded handoff slot启动，说明外层 current admission不是唯一剩余问题。

更关键的是 lifecycle矛盾：trace 中可找到多组 `demandDetached` 明确记录 `receivingRetained=false`，紧接着同 identity 又被 active `downloadPriorityChanged(... newPriority=0, reason=retained-background)` 保留。该样本至少有7组直接相邻证据。也就是说，session自己的“不是 receiving”事实与 coordinator retention决定不一致。

## 源码根因

`DownloadJob.run()` 在 restore/request-plan/open之前就建立 `RunLease`，所以 `DownloadSession.activeRun` 覆盖：

`restore → queue → source request-plan / Venera gate → HTTP open → bind response → acquire writer / receiving → stream`。

而 dev.183 `LiveCoordinator._reconcileDownloads()` 只要 `session.activeRun == true` 就把离窗任务迁到 priority 0。于是尚在 queued/opening的 source工作被误当 receiving长期保留；它既占外层 NetLane active permit，也可能继续排队/占用Venera单 invocation路径。真正的 current虽然有5+1 handoff，普通 previous仍只能等旧槽释放。

## 与 VibeVenera 的边界

继续保留两条已验证思想：

- 相邻 previous是正常窗口成员，不把上一 current 的 output retention 与 relative role混为一谈；
- running task的取消不能提前释放真实 permit，必须等待异步 transport退出。

但ZIC比VibeVenera多一层 plugin source request-plan/Venera single-invocation seam。这里不能用“外层 task已running”推导“已经 receiving”；ZIC已有 `DownloadState.receiving` 才是权威事实。

## 修改

- receiving + active：保持 `retained-background=0`。
- active + 非receiving：`NetLane.cancel(taskKey)`，沿既有 TaskControl要求 source/runtime/HTTP退出；不提前释放permit。
- queued + 非active：`cancelQueued(taskKey)`并立即退休tracking。
- 新增回归：真实 receiving detach/reattach仍 `opens==1`；pre-open active detach必须取消，并让 maxActive=1 的唯一槽交给 adjacent previous。
- 不改 previous=780、current=1000、encoded7/3、decode2/1、holder7/5/3/2、normal lane5/3/2。

## 验证限制

当前执行环境没有 Flutter/Dart SDK，因此不能在此环境执行 Dart package tests、analyzer或 Android build。已增加源码行为测试与 Python release gate；完整 `tool/check.sh` 会执行所有可用静态/Node/native检查，并明确跳过缺失 Flutter/Dart 的部分。设备侧仍需复测真实 Venera request-plan/open时序。
