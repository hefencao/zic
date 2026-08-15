# dev.302 accepted-plan 原子 reconcile 根因审计

## 输入
- 唯一代码基线：`zic_v0.31.0-dev.301_semantic-demand-revision-boundary.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-15T12-21-21.jsonl`。
- 用户症状：纵排连续滚动仍存在明显、远大于 1–2px 的固定抖动。

## dev.301 先验复核
本 Trace 中没有再出现 dev.300 那种“权威11/4/2计划不变却连续晋升 revision”的 runtime-evidence cascade，说明 dev.301 semantic revision/liveness 边界真实生效。因此不能继续把主因归结为无意义 revision 数量。

## FrameTiming 时间轴
Trace 含 1460 个 `readerFrameTiming`。相邻 vsync 的常态约16.4ms；43 个 interval >30ms。按最近 Reader interaction 映射，active scrolling/dragging/settling 中有37个 >30ms、11个 >40ms、1个 >50ms。37个 active long-gap 中28个在前100ms存在真实 `policyDecision`。

典型页边界不是 semantic no-op，而是 current/target/readDirection 等真实角色变化。此类 plan 通常仍保持总规模 11 downloads / 4 decodes / 2 uploads，但大部分 item 的 role/priority/identity membership发生合法变化。35个 policy 周期出现11项 download `demandApplied`；这些11-download同步 burst 的中位约10.456ms、p90约14.110ms、最大约15.372ms。代表性 revision 还紧接4个 decodeDemand与2个 uploadDemand。

## 源码链路
`ReaderView observation -> PipelineReaderSession.scheduleMicrotask -> ReaderBinding.accept -> PipelineController.accept -> onUpdate -> LiveCoordinator.reconcile` 仍运行在同一个 Dart UI isolate。

旧 reconcile 的合法 fan-out 为：
1. `_downloadTransfer.replaceDemands()` detach/upsert多个claim；existing claim priority经`DownloadDemandLease.updatePriority()`修改Session并迁移NetLane；每个 `net.updatePriority/updateDemanded/submit` 都立即 `_Lane._pump()`。
2. `_reconcileDecodes()` 对多个 changed/added demand调用 `DecodeLane.follow/submit`，每个立即 pump。
3. `_reconcileUploads()` 同理逐个 `UploadLane.follow/submit` 并立即 pump。
4. `_Lane._pump()` 不是O(1)标记：它扫描 pending/active、bucket、transport lease、resume/admission、retention/preemption候选，并可能同步启动 task。重复对 intermediate state 执行十几次没有新的权威信息价值。
5. `DownloadSession._setDemandPriority()` 又把纯 scheduling priority 当完整 snapshot变化，广播给 PageStream/progress/retention observer；仓库生产 consumer没有任何一个从 snapshot listener读取`effectivePriority`/`demandCount`来决定策略。

因此 dev.301 修掉的是“错误 revision”；dev.302 根因是“正确 revision 缺少 transaction boundary”。

## dev.302 收口
- `TaskLane.batch`：mutation即时写state，outermost batch退出前将所有 pump 合并为一次。
- `LiveCoordinator` 对同一 `PipelineDelta` nested batch Net/Decode/Upload，并在 liveness/source wake/budget 都完成后才释放 lane pump。
- priority-only `DownloadSession` migration不再广播内容/生命周期snapshot；新增scope与detach等真实demand lifecycle仍广播。
- `pipelineReconcileTiming`记录accepted reconcile时长与download/decode/upload diff数量；DebugTrace只存储，不为该事件schedule新frame。

## 未改变
previous3/next7、decode previous1/next2、5/3/2/1、normal5+current reserved1、priority数值、NetLane preemption/retention算法、sourceCanvas、dev.295 hidden static upload、dev.299 current±2 static projection continuity全部保持。
