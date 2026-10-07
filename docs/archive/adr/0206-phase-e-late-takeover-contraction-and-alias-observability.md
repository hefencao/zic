# ADR 0206：Phase E late takeover 收缩与 acquire alias 可观测性

- 状态：Accepted
- 日期：2026-08-11
- 版本：0.31.0-dev.226

## 背景

dev.225 已把 direct verified equivalence 前移到 physical acquire：新 exact identity 在尚无自己的 session 时，可加入唯一已有且具有 physical authority 的等价 transfer。与此同时，dev.213 的 late equivalent-full promotion takeover 仍保留作为已独立创建 session 的兼容路径。

15:01 真机 Trace 中未出现 `verified-equivalent-promotion-takeover`，但 physical transfer 到 durable store 的 partial/artifact persistence 仍持续真实命中。因此 Phase E 不能按历史名称机械删除所有 handoff；需要先区分“已被 composition owner 取代的 Reader 委托”和“仍属于 durable persistence 的正常边界”。

## 决策

1. 删除 `LiveCoordinator` 与 `DownloadTransferConsumer` 的 late-artifact refresh 委托。Reader/consumer 不再拥有或转发 equivalent promotion takeover。
2. composition promotion listener 只检查 `DownloadRegistry.findExact()` 的独立 exact session；acquire-time alias 后没有独立 session 的 identity 不再进入 legacy 扫描。
3. legacy takeover 仅保留在 `DownloadTransferOwner.refreshIndependentExactForPromotedEquivalent()`，并显式标记 `compatibilityPath=true` / `compatibilityScope=independent-exact-session`。
4. acquire-time alias 新增 `verified-transfer-acquire-alias` trace，至少区分 `joined-existing-physical` 与 `rejected-ambiguous-existing-owners`。查询/诊断 API 不得触发 alias。
5. `PartialDownloadHandoff` 与 `PromotedArtifactCacheHandoff` 本轮保留。它们当前表达的是 composition physical transfer → durable partial/cache owner，而不是 Reader A → Reader B 的补偿。

## 非目标

- 不事后 merge 两个已经存在的 physical session。
- 不删除 cold partial persistence。
- 不删除 promoted artifact → ArtifactCacheManager handoff。
- 不扩大 source-resident non-cache body 的跨版本共享。
- 不调整 NetLane、priority、水位、retry、decode/upload/presentation。

## 删除最终 legacy takeover 的门槛

后续真机/压力 Trace 必须能够直接观测 acquire-time alias 命中，同时 legacy compatibility takeover 在覆盖代表性版本切换、Reader 重入、章节下载场景后持续为 0；若仍命中，先分类其产生原因（proof 迟到、exact session 预创建、multiple owners、cold boundary），不能直接删除。
