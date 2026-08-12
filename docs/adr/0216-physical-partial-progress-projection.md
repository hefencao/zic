# ADR 0216：Physical partial progress projection closure

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.236

## 背景

03:34 真机 Trace 证明 acquire-time verified alias 已共享 physical `DownloadSession` 与 committed prefix，但 Reader 进度仍可表现为各自独立。`PipelineTransferProgressPublisher` 仍维护 exact `DownloadId.key -> DownloadSession` 表；logical alias B 与 physical anchor A 的 key 不同，因此数据 owner 已统一而 progress projection 仍分裂。

## 决策

1. current transfer progress 的唯一事实源是 demand reconcile 后由 composition `DownloadRegistry` 解析出的 physical `DownloadSession.snapshot`。
2. publisher 直接选择一个 physical `DownloadSession`，只监听该 session；删除 exact-key session map 与全 session observer fan-out。
3. selection 必须发生在 `ReaderBinding.accept` 完成之后，使 acquire-time alias 已建立。
4. Reader 继续只消费 Pipeline 暴露的只读 notifier，不获得 registry/session ownership。
5. Reader-local ingress projection 的诊断 scope 使用 physical `sessionId`；不再用 physical anchor exact ID 作为 lifecycle 名称。

## 非目标

- 不复制 committed bytes 到 logical exact session。
- 不 late-merge 已独立存在的 physical sessions。
- 不改变 provider-exact request URI、provider-scoped validator、cold partial、NetLane 或 retry 语义。
- 不把本轮剩余 full-body 200 duplicate prefix 误归因于 progress projection。
