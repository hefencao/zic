# ADR 0200：Reader navigation / pipeline observation / late ingress 边界

- Status: Accepted
- Version: 0.31.0-dev.219

## Context

dev.216 将 exact `DownloadId` 的物理传输提升到 composition owner，dev.215 保留 Reader-local native ingress/decode/upload。然而 registry wiring 仍假设“Reader第一次看到 DownloadSession 时 committedLength=0”：`DownloadIngressProjectionRegistry.get()` 同步调用 `attachIngressProjection()`。当新 Reader 重新进入一个已由共享 physical owner 下载过的 exact session 时，late projection 必须 replay 已提交前缀，旧同步调用会按 DownloadSession 合同抛 `invalidState`。

`LiveCoordinator.reconcile()` 顺序为 download→decode→upload，因此这个 Reader-local projection 异常会在 download reconciliation 中截断后续 decode/upload demand。与此同时 `ReaderController.report()` 过去直接同步调用 `PipelineReaderSession.accept()`，导致 pipeline/session 异常可以沿 ScrollNotification、page request 与 slider command 栈反向进入 UI。`ReaderRuntimeScreen.didChangeDependencies()` 还把 DecodeTarget 生命周期与 ReaderController 生命周期绑定：MediaQuery/system UI 改变 target 时会销毁导航 controller，连 pending page request 一起丢失。

## Decision

1. composition `DownloadSession` 仍是 physical bytes/writer/retry owner；Reader-local `DownloadIngressProjectionRegistry` 只拥有 consumer projection。
2. 对 `committedLength==0` 的新 physical session可同步挂 projection；对已有 committed prefix 的 session，registry必须先发布空 Reader-local projection，再异步调用 `attachSynchronizedIngressProjection()`。Demand reconcile不得等待或因 late replay 被截断；DecodeSession可先进入 `waitingSource`，replay完成后的 projection revision/source listener负责唤醒。
3. late replay失败只标记该 Reader-local ingress projection失败，不改 physical DownloadSession authority。Reader detach时只移除本地 projection；异步 replay若晚完成必须自清理 physical fan-out，不能复活已退出 Reader。
4. Reader observation进入 pipeline采用 enqueue/latest-wins microtask边界。ReaderView/ReaderController不得同步执行 demand/transfer/decode reconciliation；pipeline错误可记录，但不得 unwind UI navigation stack。
5. `ReaderController` 属于 route/navigation state。DecodeTarget 属于 pipeline/media projection。target变化不得 detach/attach binding：`PipelineController.updateDecodeTarget()`只标记decode target dirty，随后通过Reader observation enqueue基于既有DemandPlan做增量diff。physical DownloadId/demand未变化时不得出现download remove/re-add；同时不得重建 ReaderController或清除 requested/current page。

## Consequences

- 新 Reader 可复用已有 physical transfer/partial/full，同时仍建立独立 native ingress、decode、upload。
- 下载 owner、decode target或 pipeline reconciliation 的生命周期不再决定 slider/page navigation 是否完成；MediaQuery变化也不会制造全量download demand撤销/重建。
- verified TransferKey、chapter/whole-comic command claim迁移继续冻结；先通过真机证明 re-entry、slider jump、late projection和 current decode 完整闭环。
