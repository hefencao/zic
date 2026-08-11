# dev.220 navigation scrub / physical trace fan-out 根因审计

## 真机证据

输入：`zic-debug-trace-2026-08-11T09-44-20.jsonl`。

### dev.219 已确认修复的部分

- `pipeline-reader-3` 不再出现 dev.218 的 `decodeSessions=0 / uploadSessions=0` 断链；本轮退出时为 `decodeSessions=7 / uploadSessions=7`。
- `pipeline-reader-4` 也建立并持续运行 decode/upload；late projection join 主链已恢复。
- Reader2 的 slider 确实能从 148 快速推进到 248，说明 navigation 已不再被 pipeline异常同步阻断。
- 本 trace 无 `sessionBusy` / `writerBusy`，physical single-task 修复继续有效。

## 剩余耦合一：scrub preview 被当成 navigation commit

Reader2 在约 26.7–27.1 秒的一次 slider sweep 中：

- `pageCurrent` 23 次：148→150→…→248；
- `readerObservation` 92 次；
- `policyDecision` 23 次；
- `downloadPriorityChanged` 157 次；
- raw `demandApplied` 506 次、`demandDetached` 188 次；
- 5 次 download preemption；
- 17 个 page host 在销毁前没有 first frame，其中多数只是 scrub 中间页，生命周期低至几十毫秒。

源码对应：`ReaderRuntimeScreen` 的 Slider `onChanged` 直接执行 `reader.requestPage(value.round())`。因此每个 thumb 中间值都会 `jumpToPage()`，随后形成 viewport observation、RoleWindow、DemandPlan、download/decode/upload diff。这不是 scheduler 本身的失败，而是 UI preview 与 route commit 的 ownership 没有分开。

## 剩余耦合二：physical trace 经 Reader wrapper 重复写全局 sink

Trace 中有 1120 组相邻且逐字段完全相同的事件，主要为：

- `demandApplied` 612 组；
- `artifactSource` 187 组；
- `demandDetached` 154 组；
- `downloadState` 92 组；
- `sourceReady` 38 组。

时间分布与 Reader overlap 完全一致：

- 0–24.9 秒（单 Reader）：0 组；
- reader1+reader2 重叠约 24.9–46.3 秒：738 组；
- reader3+reader4 重叠约 60.6–84.7 秒：235 组。

源码根因：physical `_TransferTraceHub` attach 的是每个 Reader 的 `MultiTraceSink`；这些 wrapper各自包含独立 `MemoryTraceSink`，但又包含同一个 App Debug Trace sink。physical event广播到N个wrapper后，同一App sink被调用N次。

## 剩余耦合三：viewport projection仍位于reconcile之后

`ReaderBinding.accept()` 在 dev.219 中仍按 `pipeline.accept(observation)` → `_syncViewport(observation)` 执行。外层 observation queue 虽已 catch pipeline error，但若 coordinator reconcile抛错，本Reader的 viewport/playback projection仍不会更新。错误已不再影响UI调用栈，但presentation consumer仍被demand execution控制。

## 修复边界

- slider拖动改为UI-local scrub preview，只在gesture end提交一次navigation intent；不改Reader observation/policy参数。
- `ReaderBinding` 先保存viewport fact，pipeline accept结束或失败后都同步playback projection。
- physical trace hub改为引用计数：Reader memory sink逐Reader保留；shared App/export sink按identity只挂一次。
- 不调整network=5、decode/upload并发、水位、preemption、retry、cache、transport与verified TransferKey。
