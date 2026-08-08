# dev.174 VibeVenera 对照：Current 抢占根因审计

## 输入

- 唯一 ZIC 代码基线：`zic_v0.31.0-dev.173_migration-version-update-badge-owner.zip`。
- 只读参考：文件库无后缀权威 `vibevenera-master.zip`；不使用 `(1)/(2)`副本作为实现来源。
- 用户设备现象：预下载占满后切到 current，current仍会等待其它线程下载完成。

## 已有共同点

ZIC 与 VibeVenera均已具备：active same-key priority migration、current高优先级、低 rank active cancellation、正常 lane可满载、一个临时 high-priority handoff、取消任务真实结束前保留运行登记。

因此继续调 current priority、减少预取、增加线程数都不是根因方向。

## 关键差异

VibeVenera lane dispatch在 high-priority队首遇到 `running >= handoffLimit` 时，仍调用 `_preemptLowestRunningFor(next)` 后返回；已经收到 cancel的 running task不会再次成为 victim。

ZIC dev.173在同一状态先把 pending current从 `eligible`排除；`eligible.isEmpty`直接 break。结果是 handoff 被慢取消占用期间，新的 current没有资格再推动其它低 rank prefetch退出。

这会形成典型序列：

`prefetch x5 → current-a 产生 5+1 → victim-a慢取消 → current-b到来 → dev.173无第二次preemption → 等待某个下载自然结束`。

## 修改

`NetLane._pump()`在 eligible为空时检查 `_highestBlockedHighPriorityPending()`，若存在则仍调用现有 `_preemptLowestRunningFor()`，之后立即退出本轮 pump等待真实 cleanup。没有新增 scheduler、没有提前释放 permit。

新增 `net_lane_test.dart` 5+1回归，故意让第一个 victim在收到 cancel后长期不完成，验证 current-b仍能推动第二/后续 prefetch让位，并在真实 permit释放后启动。

## Transport cancellation 边界

ZIC `DownloadJob`的 cancel token可中断已返回 `ByteResponse` 的 stream iterator；部分 transport在 `open()`真正返回前没有统一 cancel参数。VibeVenera的 streaming transport则把 cancel token直接送到底层下载请求。

本轮没有凭无设备证据扩展跨 package transport cancel ABI，因为：

1. 当前首先存在一个已证实、且与 VibeVenera代码直接不同的 NetLane调度缺口；
2. handoff设计本来就允许第一条慢取消时 current先启动；
3. 提前释放 permit会破坏单 writer/连接上限。

若 dev.174设备 trace仍显示 victim已收到 lane cancel但长时间保持 active，下一轮应沿具体 `Transport.open/source runtime`取消传播继续收口，而不是再改 rank/线程数。
