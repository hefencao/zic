# ADR 0199：Pending source revision 与 Reader slider request projection

- Status: Accepted
- Version: 0.31.0-dev.218

## Context

composition physical download 在 dev.216/217 后可以先于 decode 完成 source/artifact。Reader-local decode 仍受 current bootstrap 的 staged refill 约束：当一个 next/next2 的 source-ready wake 被定向提交时，策略可因 current 尚未建立浅水位而合法返回空决策。空决策只代表“现在不执行这个 refill”，不代表该 source revision 已经被 DecodeSession消费。

Reader slider 也有类似的状态分层：`requestPage()` 先产生 pending requested index，真实 viewport/current index 稍后才 acknowledge。Presentation 若始终以旧 current index 控制 slider，会在每次 rebuild 把正在拖动的 thumb拉回。

## Decision

1. source revision 的 authoritative 可用状态来自 Reader-local `DownloadIngressProjection.snapshot.revision`；listener mirror只用于唤醒，不是唯一事实源。
2. staged refill 返回 null 时不得消费 pending source revision。只有实际执行 decode fill，或 DecodeSession snapshot明确证明当前无需 fill，才能推进 consumed revision。
3. role promotion/reconcile 必须重新比较 projection available revision 与 decode consumed revision，使已经ready但曾被策略门控的页面在晋升 current 时恢复decode。
4. Reader slider 在 pending request存在时以 `requestedIndex`作为受控值，acknowledge后回到`currentIndex`；slider不直接拥有导航状态。

## Non-goals

- 不改变 NetLane并发、抢占阈值、7/3 encoded窗口、7/5/3/2 holder水位或retry。
- 不建立第二套 source event queue，也不把 decode/upload全局化。
- 不推进 verified TransferKey、跨版本hot partial或chapter/whole-comic claim迁移。
