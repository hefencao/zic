# dev.272 local partial hydration / network admission 根因审计

## 设备事实

输入：`zic-debug-trace-2026-08-14T02-01-35.jsonl`（dev.271）。

Trace 中共有 13 次 `session-partial-handoff/restored`。这些都是 durable/local restore，但旧实现只有 NetLane task 真正开始后才调用 `prepareDownload`，因此 demand 到 local restore 的等待包含了网络 scheduler / transport lease 排队：代表样本 page194 约 2.40s、page203 约 3.09s；page201 成 current 后约 160ms 才完成 442,368-byte restore。page201 的 `sourceReady` 可在 restore 完成前由 262,144-byte WebP prefix先发布，证明 Reader ingress 本身具备渐进消费能力，缺口在 restore 启动时机而非 decoder。

Trace 未显示对应的 decode/upload terminal failure 主导链；问题是“durable bytes physically exist，但 usable Reader source 的 hydration 被 network admission 阻塞”。

## 旧 owner 冲突

`CompositionDownloadTransferRuntime` 将 `PartialDownloadHandoff.restoreInto` 注入 `DownloadTransferOwner.prepareDownload`，但 dev.271 的 `_runDownload` 只有 NetLane admitted 后才执行该 callback。于是：

`local durable store I/O -> physical session append -> Reader ingress`

被错误地放进：

`NetLane transport/source admission -> provider task lifetime`

本地 partial 是否可读因此被 source/socket capacity 间接控制。

## 收口

- 不把 `replaceDemands()` 改成 async；Reader planning 不等待磁盘。
- 不给 partial 新增 priority、retry threshold、grace 或独立 lane。
- `DownloadTransferOwner` 只增加 physical-generation local preparation single-flight；`PartialDownloadHandoff` 仍是 durable byte owner，NetLane 仍是 network/source scheduler。
- local prepare 与 local completion 完成后才决定是否创建网络 task。
- 为避免3/7前移后制造11路无界磁盘copy，cold partial chunk与artifact-cache replay复用同一composition `ArtifactCacheReadScheduler`；不新增local scheduler。
- local prepare failure 只降级到 provider fallback，不重复 cold restore。

这样把 demand planning、本地 physical hydration、network admission 三个时序事实重新分开，同时保持一个 physical session / writer。
