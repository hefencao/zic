# dev.205 Reader partial 生命周期根因审计

## Trace 证据

12:24 trace 产生新 `readerSessionCreated`。启动窗口中 current download 以 `committedLength=0` 开始；相邻两个页面随后分别从 `persistent-artifact` 读取约15.7MiB与19.7MiB完整 artifact。说明 durable promoted cache 本身正常，缺失的是未 promoted partial 的跨真实 Reader session 生命周期。

最后 page216 的 download identity 为 `identity:<-206294c755959107,179>`，decode identity 为 `identity:<610781e182f591b0,213>`。此前该动画已解出前25帧并在 frame25 等待 `requiredSourceLength=3,145,728`；之后 download partial 保留在 `3,105,420` bytes。holder 被消费并 detach 后要求 cursor 从 frame0重建，但 DecodeSession 旧顺序先用 frame25 requirement 检查 source length，再执行 cursor restart，因此 3.1MiB partial 被错误判定为仍需网络增长。重新成为 current 后服务器忽略 Range，full-body catch-up从0验证旧prefix；直到约66.87s越过旧 boundary才产生新 source growth，page216 从约60.55s mount 到约67.18s first frame，黑屏约6.62s。

## 代码根因

- `EphemeralCacheWorkspace.readerSession(...)` 的未 promoted artifact 随真正 session dispose 删除。
- `PromotedArtifactCacheHandoff` 只接收 sealed/promoted完整 artifact；`ArtifactCacheBackend`此前没有 partial 类型。
- Reader pool 的短期 retain 不是 durable partial storage。
- `DecodeSession.fill()` 中 `_restartCursorWhenHolderEmpty` 的处理位于 nonsealed `_requiredSourceLength` gate 之后，允许旧 later-frame hint 阻塞新的 frame0 cursor。

## rhttp/client 边界复核

最终 page body 在 request plan 完成后由 `SourceResourceTransport` 的 Flutter rhttp host transport执行；Venera JavaScript `Network.*` resolver调用仍在 plugin-host Kotlin `HttpURLConnection`内。dev.204只是改变既有 resolver connection 正常完成后的 disconnect行为，并未新建第二 scheduler。此前“rhttp client已收口”的表述应修正为“最终 media host replay已收口”；resolver source-owned client仍是独立连接池/架构债务。

## dev.205 决策

- durable partial 复用现有 ChapterDownloads DownloadRegistry/Artifact/CacheIndex，独立于 promoted immutable cache。
- retain时异步checkpoint固定 prefix boundary，dispose时final drain；新 session在网络前restore。
- holder-empty cursor restart前移到 stale next-frame requirement gate之前。
- 本轮不迁移 Venera resolver transport，避免与 partial correctness同时改变 requestId cancellation/Cookie/cache/runtime重入。
