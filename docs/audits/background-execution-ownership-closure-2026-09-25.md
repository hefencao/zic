# Background execution ownership closure audit — 2026-09-25

## 范围

本审计复核静态纵排/缓存性能修复中新增或扩大使用的后台 execution seam，并专门回答：哪些工作真的需要离开 UI isolate，哪些只需要异步让出 frame，哪些继续同步反而更简单、更快。

主链：

`Reader -> PipelineReaderSession -> PipelineController/LiveCoordinator -> DownloadTransferOwner -> DownloadSession -> DownloadIngressProjectionRegistry -> Ingress/native source`

并覆盖：

`PersistentDownloadArtifactStore -> SqliteIndex -> artifact read/touch worker`

以及 external-static presentation cache maintenance。

## 判定规则

后台化不是目标。保留 worker 必须同时满足：

1. 原操作在 UI isolate 上有可测的毫秒级 CPU/同步 FFI/磁盘阻塞风险；
2. work 在提交给 worker 前已经由唯一 owner/scheduler 接纳；
3. priority、cancellation、generation/authority fence 能原样跨 execution seam；
4. worker 不增加第二份 retry、eligibility、resource identity 或 plan lifecycle。

如果只是很短的 map/index/control 计算，则优先同步；如果只是要避开当前 frame，则使用同 isolate 的 event-loop/frame scheduling，而不是新线程。

## 最终 owner 图

| 状态/动作 | 唯一 owner | 执行方式 | 结论 |
| --- | --- | --- | --- |
| viewport / gesture observation | Reader | 同 UI isolate；latest-wins，必要时 after-frame drain | 保留异步时序，不上 worker |
| page demand plan / reconcile | PipelineController / LiveCoordinator | 同 UI isolate | 保持同步 owner transaction |
| physical carrier / writer / local prepare / retry | DownloadTransferOwner | owner-local control；local I/O本身可异步 | version candidate worker撤销 |
| Reader-local encoded replay | DownloadIngressProjectionRegistry | 有界 owner queue + native source workers | 保留 worker |
| encoded source epoch/length/kind/sealed | Ingress | owner state；重 copy/FFI 可 worker | 保留单一 state owner |
| native source memory mutation | NativeSource | 2个 source-write isolate workers | 保留，消费上游 rank/cancel |
| durable artifact metadata | SqliteIndex | persistent SQLite read/touch workers | 保留，owner/scheduler不变 |
| external-static raster residency/LRU | PipelinePresentationRasterCache | owner内部 idle/deferred maintenance | 保留异步，不另建 owner |
| network download | DownloadTransferOwner + NetLane | transport async I/O | 不新增 download thread pool |

## 证据与结论

### 1. native source write：必须真正离开 UI isolate

旧 trace 中可配对的 `resident-ingress-hydration` 共 73 次：median **5.835ms**、p90 **10.519ms**、p95 **12.104ms**、max **14.803ms**；43次 >=4ms、23次 >=8ms、5次 >=12ms。

这些 reserve/copy/file-range FFI/memory work 单次就足以吞掉 120Hz frame budget，不能靠 `async` 关键字解决，因为同步 FFI/memcpy 仍会在调用 isolate 执行。

最终边界：

- `DownloadIngressProjectionRegistry` 仍决定 replay admission 和 maxActiveReplays；
- 同一 `_IngressAttachmentControl` 的动态 priority/cancellation 贯穿 projection/Ingress/background source 到 worker；
- worker pending 按实时 rank 选择，同 rank 保持提交顺序；queued cancellation 撤销尚未执行 work；
- 已进入 native operation 的任务必须真实退出才释放 worker，避免“取消即释放 slot”制造伪并发。

此前 source-write pool 曾被 decode prewarm/shutdown API 隐式拥有，现拆成显式独立 lifecycle，由 composition 并列管理。

### 2. SQLite read/touch：保留 worker，但不是为了追求吞吐数字

host file-backed microbench：artifact authority 的直接 owner connection 三组查询约 **130.1µs/call**，persistent read worker roundtrip约 **123.9µs/call**；conditional touch 直接执行约 **2.423ms/call**，worker roundtrip约 **1.803ms/call**。

read worker 的收益不是让单次查询显著更快，而是避免真实设备 I/O pressure 下 sqlite3 prepare/step 同步占住 UI isolate。touch 已经是明确的毫秒级同步写风险。

收口要求：

- artifact object + replica + storage root 在 worker 独立只读连接的**同一个 read transaction**形成 snapshot；
- worker启动/读取失败可回退 `SqliteIndex` owner connection，辅助 worker不是 durable authority；
- touch 必须先经过 composition 已有 `StorageWriteScheduler` admission，再交给 worker执行一次 conditional UPDATE；
- worker不得再自建 debounce/retry timer或第二套 write scheduler。

### 3. version candidate isolate：复杂度高于收益，撤销

该路径只是 Reader 新进入工作集的少量 page identity / relation candidate 查询。为了把它送入 `Isolate.run`，曾新增：worker-safe projection、authority revision、candidate batch、`TransferPreparedIdentity`、consumer mutation generation、prepare/commit 两阶段 demand、LiveCoordinator latest-wins reconcile drain 和 stale prepared retry。

这些机制实际复制了 plan mutation protocol，却没有对应的毫秒级阻塞证据。版本 candidate 本身也不持磁盘/网络/FFI slot。

因此本轮撤销整条 background candidate preparation：

- `VersionPageAuthority` 恢复同步 direct candidate authority；
- `DownloadTransferOwner` 新 logical acquire 直接执行已有 acquire-time resolver；
- `LiveCoordinator` 恢复一个同步 reconcile transaction，不再维护 pending prepared plan/generation fence；
- retained logical id 仍复用既有 acquire-time physical carrier，避免每次 role/priority migration 重跑 equivalence。

这里选择的是**同步**，不是“换成另一种线程”。

### 4. source-ready wake：额外 deferred queue 无独立价值，撤销

source revision 到达后实际工作只是唤醒已有 decode demand。额外 `pendingSourceWakes + scheduleControlDrain + after-frame/Timer` 并没有把重 CPU/FFI 移走，只给 producer→consumer 边增加了一套 pending 状态。

现恢复 LiveCoordinator owner 内直接 `_wakeDecodesForSource`。真正 decode work仍由 decode lane/native decode worker执行；控制 wake本身保持短小同步。

### 5. Reader observation：保留“异步时序”，但它不是多线程

`PipelineReaderSession` observation reconcile 仍是 UI-isolate control work。已有 profile 曾显示 observation drain median约2.9ms、max约8.2ms，并与多数 >=12ms frame gap重叠。把已有 frame pending 时的 drain 放到 frame 后，可以避免控制事务先于视觉 frame运行。

这里不应上 isolate：reconcile读写大量 owner-local对象，跨 isolate 只会迫使复制状态。正确方案是 latest-wins + ordinary event/after-frame scheduling，仍由同一个 owner串行执行。

### 6. network/download：异步 I/O即可，不额外多线程

网络等待本身已经由 transport Future + `NetLane` 管理。增加 download worker pool不会让 socket I/O更“异步”，只会复制 priority/cancel/admission。真正需要 worker的是响应到达后会在 Dart isolate上同步消耗 CPU/FFI 的阶段，而不是网络等待本身。

## 回归与治理

撤销 over-background 路径后，focused 回归继续覆盖：

- sessions transfer owner/live coordinator：73 tests passed；
- pipeline_runtime ownership/direct presentation：42 tests passed；
- downloads version authority/partial handoff/retention：58 tests passed。

后续全量 validation 从独立 staged-tree执行；不得再以 dirty worktree 掩盖缺失 import、source-token gate或未提交依赖。

## 不变边界

本轮不改变 7/3 download、2/1 decode、static warm、local prepare max2、NetLane、ScrollPhysics、raster budget、cache root策略。后台化只允许改变**执行位置/时机**，不得改变谁有资格创建、取消、重试、绑定或淘汰资源。
