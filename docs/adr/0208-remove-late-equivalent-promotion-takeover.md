# ADR 0208：删除 late equivalent-promotion takeover

- 状态：Accepted
- 日期：2026-08-11
- 版本：dev.228

## 背景

dev.225 将 direct verified equivalence 前移到 physical acquire；dev.226 把历史 late takeover 收缩到 composition owner 的 independent-exact compatibility path；dev.227 修复 physical anchor 与 provider exact request URI 混淆。15:57 真机 Trace 中 acquire alias 共 18 次，其中 8 次目标是 failed partial；这些 transfer 可继续被新 provider exact identity激活，同时 `unsupported URI scheme`、task failure 与 decode failure均为0。legacy `verified-equivalent-promotion-takeover`仍为0。

## 决策

1. 删除 `CompositionDownloadTransferRuntime` 对 ArtifactCacheManager promotion event 的监听。
2. 删除 `DownloadTransferOwner.refreshIndependentExactForPromotedEquivalent()`。
3. 删除 ArtifactCacheManager 的 promotion-listener API；artifact promoted commit只负责cache/durable事实，不再作为physical scheduling event bus。
4. direct verified equivalence registry继续保留，并且只允许新的 demand acquire 通过 `verified-transfer-acquire-alias`改变physical identity。
5. 已经分别存在的physical session不因另一版本随后promote而事后merge、cancel或restart。
6. `session-partial-handoff`与`session-artifact-handoff`继续保留为composition physical→durable store边界，不属于本ADR删除范围。

## 后果

Phase E 的 equivalent-full late takeover补偿正式结束。后续若发现强等价页仍重复下载，应从proof恢复、acquire时序、ambiguous existing owners或cold partial coverage分析，不得恢复artifact promotion observer作为事后补偿。
