# ADR 0213：Physical reuse 与 handoff lifecycle 收口

- 状态：Accepted
- 版本：dev.233
- 范围：verified physical acquire、hot/cold partial ownership、promoted artifact handoff

## 背景

01:05 真机 Trace 已不再出现 dev.232 所针对的 `partial-source taskFailed`，但出现两类新的重复所有权证据：28 次 `verified-transfer-acquire-alias` 中有 2 次 `rejected-ambiguous-existing-owners`；同一 promoted immutable identity 又会随着 demand attach/detach 和 promoted snapshot 重复产生 `skip-existing` / `skip-verified-equivalent-durable` backend probe。与此同时，`DownloadTransferOwner.persistUnclaimed` 仍把 durable partial policy 以 callback 注入 sessions 调度层，使 logical claim lifecycle 可以触发 cold-store I/O。

## 决策

1. **multi-owner verified proof 不再创建第三 physical owner。** 新 exact identity 尚无 exact session 时，收集所有 direct verified、可 join 的既有 physical session；按 promoted → active writer/run/receiving → demanded/queued → committed partial 排 authority，再按 committed length、demand count、effective priority、稳定 DownloadId key 确定性择优。只 alias 到选中的既有 owner；两个已经存在的 owner 绝不互相 merge。
2. **failed partial 不是应清理的“坏 owner”。** cancellation/preemption 形成的 failed session只要仍有 committed prefix 就是可恢复 physical authority，排序低于 active/promoted owner但高于创建新 transfer。真正不可 join 的仍是 disposed 和 source-resident non-cache body。
3. **cold partial persistence 从 sessions 解耦。** 删除 `TransferPersistUnclaimed`、`persistUnclaimed` 与 `_unclaimedFlushes`。logical claim detach 仅改变 scheduler demand；hot partial继续属于 `CompositionDownloadTransferRuntime`。只有 composition runtime 真正 retire/dispose、active task 已退出后，downloads owner才调用 `PartialDownloadHandoff.drain(registry.sessions)`。
4. **promoted automatic handoff 对 immutable session 一次成功即完成。** `PromotedArtifactCacheHandoff`记录成功的 automatic commit；后续 promoted snapshot/demand churn不再重复查询backend。显式 `persist(session, exactId)` 不使用该完成记忆，仍等待当前自动 commit 后重新执行 exact durable barrier，保持 dev.231 required target contract。

## 不采用

- 不恢复 dev.228 已删除的 late takeover，也不把两个已经存在的 physical session 事后合并。
- 不因为 state=failed 就删除/拒绝 partial owner；本轮 Trace 中 failed download state 全部来自 cancellation/preemption，这类 prefix 正是复用资产。
- 不用“遇到多个 owner 就创建 fresh exact session”规避选择，因为这会把 2 个 owner 扩增为 3 个，反而放大重复 network/artifact ownership。
- 不在 PartialDownloadHandoff 内增加每-route memo 来掩盖重复调用；根因是调用生命周期错误，应删除 sessions→durable policy 注入。
- 不把 automatic handoff completion cache用于 explicit required barrier；显式离线完成必须以当前 exact durable backend 状态为准。
