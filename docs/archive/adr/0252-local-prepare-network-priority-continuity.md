# ADR 0252：local prepare → network admission 优先级连续性

- 状态：Accepted
- 版本：`0.31.0-dev.274`

## 问题

dev.272 将 durable local prepare 前移到 NetLane 之前是正确的 ownership 分离，但其完成回调直接调用 `_ensureDownloadTask()`，使异步本地探测/恢复的**完成顺序**重新定义了 source/network task 的创建顺序。04:00 Trace 中 current priority=1000 虽最先下发 demand，却在 820/760/740 三个 speculative local miss 之后才创建 network task；Venera 单 invocation gate随后不得不靠 preemption补救，冷 current 首帧仍可达数秒。

## 决策

1. `DownloadTransferOwner`继续唯一拥有 pre-NetLane physical local prepare；NetLane仍是唯一network容量/preemption scheduler。
2. local prepare完成后不得直接提交network task，而进入 composition-owned **post-local admission arbiter**。
3. 若仍有 demanded、且 `effectivePriority` 更高的 physical session处于local prepare，则较低priority的已准备任务 MUST 等待；higher prepare完成/失效后按当前 `effectivePriority` 重新裁决。
4. 该barrier只跨越physical owner内部的local→network seam，不增加连接槽、不改变NetLane rank，也不扩大Venera JS并发。已经不存在higher local prepare时应立即交给NetLane。
5. demand detach、physical retire/dispose必须清除待admit状态；priority revision必须使用session当前聚合priority，不冻结开始prepare时的rank。

## 编译契约

`Validators`只公开`isEmpty/canResume`。durable partial metadata的validator URI scope判断使用`validators.canResume`，不得假设集合式`isNotEmpty` API。跨包接口必须由dev gate直接检查真实类型契约。
