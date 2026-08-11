# dev.219 Reader / Pipeline 耦合根因审计

## 真机证据

输入：`zic-debug-trace-2026-08-11T08-19-44.jsonl`。

- `pipeline-reader-3` 打开371页章节，current=328；首个 `policyDecision` 明确给出 downloads=11、decodes=4、uploads=4。
- 随后只出现11个 scoped physical `demandApplied`，没有任何 `decodeDemand` / `uploadDemand` / `decodeStarted` / `uploadStarted`。
- 约21秒后 page 328 以 `firstFrameReady=false` 销毁；Reader retention统计为 physical registry已有157个 sessions，但本Reader `decodeSessions=0 / uploadSessions=0`。
- reader-3 是回到此前371页版本；composition physical owner已经保留同 exact DownloadId 的 committed/promoted session，因此该问题只在“late Reader consumer加入既有physical transfer”后稳定显化。reader-2打开不同377页版本时大多数 exact session仍是新建，未触发同一入口条件。

## 源码根因

1. `DownloadSession.attachIngressProjection()` 明确拒绝 committedLength!=0 的 late attach，并要求 `attachSynchronizedIngressProjection()`；这是正确的 physical authority约束。
2. 但 `DownloadIngressProjectionRegistry.attach/get()` 仍无条件调用同步 `session.attachIngressProjection(projection)`。`PipelineReaderSession._observeDownloadSession()`和`LiveCoordinator._watchSource()`都会走该 registry。
3. `_observeDownloadSession()`异常被局部吞掉，但 `_watchSource()`没有吞；所以 `LiveCoordinator.reconcile()`在 `_reconcileDownloads()` 内终止，永远到不了 `_reconcileDecodes()` / `_reconcileUploads()`。Trace中的“plan有4/4、runtime为0/0”正是该控制流。
4. `ReaderController.report()` 同步执行 pipeline callback；ReaderView page jump/scroll observation因此与 pipeline reconcile异常处于同一调用栈。pipeline错误可以阻止 page-request completion/acknowledge，形成“slider thumb能拖，current页码和viewport不变”。
5. 独立审查还发现 `ReaderRuntimeScreen.didChangeDependencies()` 在 DecodeTarget变化时销毁/重建 ReaderController；system UI/MediaQuery变化因此能丢 pending navigation request。即使只保留ReaderController而继续调用pipeline `detach→attach`，`ReaderBinding.detach()`仍会把全部download/decode/upload demand先reconcile到空，再从空重建，因此一次UI target变化仍会扰动physical transfer claim。Decode target、导航controller和download demand本不应同生命周期。

## 修复边界

- 修正 Reader-local late projection wiring，而不回退 composition physical owner。
- 将 Reader observation变为 enqueue/coalesced seam，禁止 pipeline reconcile反向进入 UI callback。
- DecodeTarget更新不再detach binding：只更新PipelineController target并标记dirty，由下一条enqueue observation从既有plan增量重算；仅decode/upload identity随raster target变化，download demand保持连续。ReaderController不重建。
- 不修改 network=5、NetLane priority/preemption、水位、retry、full-body cost admission或verified equivalence。
