# dev.177 根因审计：Retained Receiving、嵌套 Venera 抢占与下载管理首帧

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.176_response-abort-artifact-crc-hotpath.zip`
- 设备 Trace：`zic-debug-trace-2026-08-09T00-50-27.jsonl`
- 只读参考：文件库权威 `vibevenera-master.zip`

## Trace 与 VibeVenera 对照

Trace中 `retained-background` 表明旧页离开encoded窗口后仍可能继续receiving。最初候选据此尝试“detach即精确cancel”，但VibeVenera源码明确否定这种泛化：`StreamingSessionCoordinator._reconcileDownload()`在无demand且transport==receiving时直接return；`StreamingDownloadTask.retainWhenInactive=true`。其scheduler只取消离开working set的queued任务，并在真正有更高priority工作等待时抢占最低rank running download；handoff已满时也继续请求低rank victim退出，但不提前释放permit。

这解释了为什么直接cancel会制造新的下载冗余：用户只是在相邻页前后滑动时，同一页可能在数百毫秒后重新变成near/current；若每次detach都断开，source不支持Range时会整页重下，即使支持Range也会重复建连与source-plan。

## ZIC额外瓶颈

ZIC还有Venera单上下文runtime gate。NetLane cancel某个低rank task并不保证被取消的正是当前占用Venera JS上下文的invocation。dev.175虽然让waiter按priority排序，但active invocation原先只能自然结束。因此dev.177在该唯一permit上增加同样的pressure-preemption：只有后到current(1000)相对scheduler-controlled active invocation满足priority差门槛时，才请求cancel active runtime request；logical detach本身不cancel。

## 下载管理首帧

Home `_openDownloadManager()`没有await；延迟来自新route `initState()`在下一帧前用microtask启动queue ready、全库chapter inspect和cache inspect。dev.177首帧直接消费Home现有snapshot，后端bulk refresh改到`addPostFrameCallback`后，并用`inspectMany()`统一扫描owner。

## 本轮清理

- 撤销未冻结的“detach即cancel”候选，不进入正式dev.177。
- 恢复dev.174与VibeVenera一致的bounded saturated preemption，不把它错误标为退优化。
- 保留dev.175 TaskControl/Venera/transport控制面与native锁修复。
- 保留dev.176 full-response abort和artifact checksum热路径迁移。
- 不新增取消防抖timer、延时阈值或第二套prefetch状态机；防抖来自“receiving retain + pressure-only preemption”本身。
