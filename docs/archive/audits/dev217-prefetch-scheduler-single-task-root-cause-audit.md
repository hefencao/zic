# dev.217 预下载调度失效根因审计

## 输入

唯一代码基线：`zic_v0.31.0-dev.216_composition-physical-transfer-owner.zip`。
设备证据：`zic-debug-trace-2026-08-11T05-59-23.jsonl`。

## Trace 事实

Trace 共 6744 条事件。与本缺陷直接相关：

- `demandApplied`：1030；`downloadPriorityChanged`：410；说明 Reader policy 正常持续产生并迁移下载需求。
- `downloadStarted`：257，但仅涉及40个unique identity；其中175次同identity再次start的间隔小于1秒，最短约151µs；同时出现 51 次 `Failure(sessionBusy): download already has an active transport run`。
- 另有 2 次 `Failure(writerBusy): cannot restore while a writer is active`。
- `sessionBusy` 又产生 114 次 `download-attempt` retry（attempt 2 为59次、attempt 3为55次）。
- `downloadPreempted` 只有16次，不能解释上述 retry 风暴；失败来自同一physical session内部竞争，不是正常current抢占。

因此“预下载失效”并不是7/3窗口、priority数值或network=5不足。NetLane被重复physical task和其重试占用，真正不同page的prefetch无法按原rank获得槽位。

## 源码根因

`DownloadTransferOwner._ensureDownloadTask()` 的dev.216逻辑：

1. 读取 `_networkTaskKeys[id]`；
2. 若存在，只执行 `_migrateDownloadPriority(...)`；
3. **继续向下执行**；只要`session.activeRun`当时还是false，就生成新的`transfer:<sequence>:<id>` key并再次`submitRanked()`。

queued task尚未进入`DownloadJob.beginRun()`时`activeRun=false`，所以快速policy revision尤其容易累计多个不同key。NetLane只按key去重，无法知道这些key其实属于同一`DownloadId`。多个task随后并发启动，第二个进入`beginRun()`得到`sessionBusy`；durable partial restore阶段还可能撞到active writer形成`writerBusy`。

## 修复边界

- existing key仍在NetLane（queued或active）时：只迁移priority并立即return。
- owner map存在但lane已退休key时：清理stale key后才允许新submit。
- `_runDownload`入口验证当前authoritative task key，stale lane entry直接退出。
- admission同时检查`session.hasWriter`。
- 不调整network concurrency、prefetch窗口、水位、RetryPolicy次数或source transport；这些都不是本次根因。

## 回归证据设计

新增Dart行为测试先用外部blocker占满`NetLane(maxActive:1)`，让目标图片保持queued；随后对同一exact id连续执行
700→720→780→1000 demand revision。稳定契约要求：

- `owner.taskKeyFor(id)`始终是第一次创建的key；
- `net.queued`始终只有1个目标transfer；
- queued task priority原位升到1000；
- blocker释放后transport只open一次并promotion成功。

该测试精确覆盖dev.216静态测试遗漏的“task尚未active时多次priority change”窗口。
