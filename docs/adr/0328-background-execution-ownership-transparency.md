# ADR 0328：后台执行必须保持 owner 与 scheduler 透明

**Status:** Accepted

## 背景

近期静态纵排优化把若干工作移出 Flutter UI isolate。复审后需要区分三件事：

1. **异步**只改变“何时继续”，不会自动把 CPU/FFI 工作移到别的线程；
2. **isolate/native worker**才真正把阻塞或 CPU 工作移出 UI isolate，但会引入消息复制、生命周期、取消和调度复杂度；
3. **短小的 owner-local 控制计算**如果本身远低于 frame budget，放进 worker 反而会新增 generation fence、latest-wins queue 和第二阶段 commit，却没有可观收益。

因此“后台化”不是默认方向。只有已经证明会占用 UI frame budget、并且上游 owner/scheduler 事实可以原样跨 execution seam 传播时才保留 worker。

## 证据

- 旧 trace 的 Reader-local resident ingress hydration 共 73 个可配对区间：median **5.835ms**、p90 **10.519ms**、max **14.803ms**；其中 23 次 >=8ms、5 次 >=12ms。这个量级足以单独吞掉 120Hz/60Hz 的大部分 frame budget，因此 native reserve/copy/file-range 必须离开 UI isolate。
- host file-backed SQLite microbench 中，artifact authority 三组直接查询约 **130.1µs/call**，persistent read worker roundtrip约 **123.9µs/call**；worker不是为了提高吞吐，而是隔离 sqlite3 prepare/step 在真实设备 I/O pressure 下的同步阻塞风险。conditional touch 直接 owner connection约 **2.423ms/call**，worker roundtrip约 **1.803ms/call**，更明确不应占 UI isolate。
- version-page candidate 对 Reader 工作集只是少量 immutable map/index 查询。把它放进 `Isolate.run` 会要求 projection serialization、authority revision、prepared-demand object、stale commit fence 和 LiveCoordinator latest-wins drain。复审未找到与这些复杂度匹配的阻塞证据，因此撤销该 worker 路径，恢复 transfer owner 内同步 acquire-time resolution。
- source-ready wake 本身只是已有 source revision 触发 decode lane wake。另建 frame-deferred pending map/scheduler没有独立重活可隔离，也会延迟 producer→consumer 边；因此撤销该额外 queue，直接在 LiveCoordinator owner 内执行 wake。

## 决策

后台 executor 只执行已经由上层 owner 接纳、且有可测阻塞理由的 work；不得为了“异步”复制第二套资源状态机。

- `PipelineReaderSession / LiveCoordinator` 仍消费唯一 Pipeline plan；`DownloadTransferOwner` 仍拥有 physical carrier、writer、local prepare 与唯一 NetLane admission。version-equivalence/canonical carrier 的 acquire-time resolution保持同步 owner-local；不得再通过 isolate preparation + two-phase commit 复制 plan mutation protocol。
- Reader observation 的 latest-wins drain可以在已有 frame pending 时延后到 frame 后执行。这是**同一 UI isolate 上的 event-loop scheduling**，不是多线程；它只让短控制事务避开视觉 frame，不产生第二 owner。
- `DownloadIngressProjectionRegistry` 仍拥有 Reader-local replay operation queue。其 `PriorityObservableTaskControl` 必须贯穿 `Ingress -> BackgroundWritableEncodedSource -> native source-write worker`。worker pending queue按实时 priority 取任务；queued cancellation直接撤销 pending work；已经进入 native operation 的 work 必须真实返回后才释放 worker。
- native decode worker 与 native source-write worker具有独立、显式的 composition lifecycle：分别 prewarm/shutdown。两者是真正的 isolate/worker 执行域，因为 decode、native memory reserve/copy/file-range 都可能消耗毫秒级 CPU/FFI 时间。
- `Ingress` 是 encoded source epoch/length/kind/sealed 的唯一逻辑 owner。同步 append 与后台 append/rebuild 只是 live transfer 和 replay/materialization 的执行 seam，不能维护两份状态。
- `SqliteIndex` 是 artifact metadata owner。background authority reader使用独立只读连接，但一次 artifact-object/replica/root 读取必须处于同一个 SQLite read transaction；worker失败可回退 owner connection。recency touch必须先经过既有 `StorageWriteScheduler` admission，再由 SQLite worker执行一次 conditional UPDATE；worker不得自建 debounce/retry/write scheduler。
- presentation raster idle maintenance仍属于 `PipelinePresentationRasterCache` owner；延后执行只改变执行时机，不改变 eviction/rescue authority。
- network I/O继续依赖异步 transport + `NetLane`，不得为“多线程”额外建立 download worker pool。Dart `async` 已足以表达等待；真正需要 isolate/thread 的只有会在 UI isolate 上实际执行 CPU/同步 FFI 的重活。

## 明确禁止

- Reader/UI 自建 background download/decode/prefetch queue；
- 为少量 map/index/identity 控制计算新增 isolate、revision fence或two-phase commit；
- source/storage worker复制 7/3、2/1、current/next 等页面策略；
- background worker用独立 FIFO 覆盖已有 scheduler rank/cancellation；
- worker completion直接绑定/替换 physical session、cache authority 或 Pipeline plan；
- 为了异步化新增 retry/revalidation/tombstone 状态机；
- cancellation 后在 native/file operation 尚未退出时先释放并发 slot。

## 验证

- media ingress + resident ingress focused tests证明 scheduler control 到达 background native source seam；
- transfer owner/live coordinator tests在撤销 background candidate prepare 后继续覆盖 acquire-time physical identity复用、priority-only migration和 source-ready decode wake；
- storage worker tests证明 immutable authority snapshot、conditional recency execution与既有 storage-write pressure admission；
- isolated staged-tree tests、documentation/ownership gates与 `tool/check.sh` 作为合入门槛。

该决策不改变 Pipeline 7/3 download、2/1 decode、static warm、NetLane、Reader ScrollPhysics 或 presentation cache budget。
