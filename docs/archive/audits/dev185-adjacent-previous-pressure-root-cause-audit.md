# dev.185 Adjacent Previous 普通槽压力根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.184_receiving-state-detach-current-previous-handoff.zip`
- 设备证据：`zic-debug-trace-2026-08-09T09-43-55.jsonl`
- 只读参考：文件库 `vibevenera-master.zip` 对应源码归档

## 结论

本轮问题不是 previous policy 丢失，也不是 previous=780 数值过低；是 `NetLane` 对 **blocked normal work** 缺少 pressure preemption。dev.184 已把 detach 的 receiving 判据纠正，但“真正 receiving 的 retained=0”仍能合理继续 active；如果 normal 5 slots都被它和较低 speculative work占用，previous=780只能等自然完成，因为现有 `_pump()` 只有 `priority >= highPriorityThreshold` 的 current/high work在 `eligible.isEmpty` 时会调用 `_preemptLowestRunningFor()`。

## Trace 证据

### 1. previous demand 正常生成

revision 18：adjacent previous identity `176d88bf...` 从 660→780，`active=false`。同一时刻有 current=1000、transition/near=900/800 等 active工作。

revision 21：`648266c4...` 从 660→780，`active=false`；同一窗口同时存在 active 760 与 740 work。其 decode previous=780可以立即开始，说明角色解析和 decode demand均正常。

### 2. previous 等低 rank active 自然完成

`648266c4...` 在 t=33,171,819 µs 提为780，直到 t=35,037,589 µs 才 `downloadStarted`，等待 **1,865,770 µs（约1.866 s）**。就在其启动前，priority 760 的 `3b6e1483...` 完成 source read、seal、promotion并自然释放普通槽。

若 NetLane 已允许 normal 780 pressure，则780相对740恰好达到既有40分门槛，本应请求该更低rank任务取消，而不是等待自然完成。

### 3. 有物理 cancellation 时 previous 很快接管

revision 29：`308e09a6...` 在 t=49,912,228 µs 提为780。两个旧 active task随后以 `Failure(cancelled)` 真实退出，previous在 t=49,958,183 µs启动，间隔 **45,955 µs（约46 ms）**。这证明 permit释放后的 queue/admission本身正常。

### 4. dev.184 的 retained receiving 语义本身正确

大跳页后 `79a3ece9...` 记录 `receivingRetained=true`，随后 active priority从1000降为0。该 transfer 已是真实 receiving，因此 dev.184/ADR 0167要求无压力时保留原连接是正确行为；不能为 previous机械取消所有 retained receiving。

## 源码审计

`packages/sessions/lib/src/net_lane.dart` 的 `_pump()` 在普通 `eligible` 为空时，只查询 `_highestBlockedHighPriorityPending()`；因此只有 current/high-priority pending会继续触发 `_preemptLowestRunningFor()`。priority 780 即使被 priority0/740/760 active work阻塞也不会形成 pressure。

`_preemptLowestRunningFor()` 本身已经满足所需安全性质：

- 只选更低 priority 且 preemptible 的 active victim；
- 要求差值达到 `preemptionThreshold`；
- 只发送 cancellation；
- victim真实 task结束前 lane/bucket permit不释放。

因此无需新增 scheduler、无需改 DownloadJob/Reader ownership，只需让 Reader 的 blocked normal 780+ work也能进入现有 pressure路径，并禁止它借 current-only handoff。

## 只读 VibeVenera 对照

VibeVenera scheduler区分 normal capacity 与 reserved high-priority handoff，running retained download可以 inactive保留，同时 stronger waiting work可形成 preemption pressure；取消的 running task也要等异步清理后才释放 permit。ZIC沿用这两个结构性原则，但保留自身固定 previous=780、current=1000和窗口策略，不复制其完整 rank表。

## 修复范围

- `NetLane`：可选 normal-pressure floor；blocked normal task可请求一个低rank victim unwind。
- `PipelineReaderSessionFactory`：Reader network floor=780。
- tests：冻结“不借handoff、等物理退出”和“retained receiving在adjacent previous压力下让槽”。
- 不修改 heuristic priority、水位、窗口、decode/upload并发或 Venera并发。
