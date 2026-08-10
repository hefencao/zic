# ADR 0188：Download-owned partial 与 Venera resolver rhttp 收口

## 状态

Accepted；取代 ADR 0186 的 Kotlin HTTP keep-alive 优化，以及 ADR 0187 中 route-retain checkpoint / ArtifactCache partial wiring。ADR 0187 的 decode cursor-reentry correctness 继续有效。

## 背景

dev.205 的 12:24 trace 找对了两个 correctness 问题，但 durable partial 的初版落点扩大了错误 owner：`ArtifactCacheManager` 被要求探测 mutable partial capability，Reader route retain 又额外 checkpoint，而现有 `_PipelineReaderSessionRetentionPool` 本来就会保留整个 DownloadRegistry/DownloadSession/DecodeSession 供同 chapter 快速重入。用户进一步要求按 VibeVenera 的清晰 ownership 重审，并明确 ZIC 特有的约30帧 partial循环必须保留但不能污染 cache/network owner。

同时 dev.204 只优化了 Venera resolver 的 Kotlin `HttpURLConnection`；最终 media 已使用 rhttp，但 resolver `Network.*` 仍拥有另一套 HTTP client/DoH/reflective OkHttp fallback，形成两个 client family。

## 决策

1. hot partial 唯一 owner 是 retained `PipelineReaderSession` 内的 DownloadRegistry/DownloadSession/Artifact。普通 Reader detach/reentry只保留/恢复该 session，不 checkpoint、不复制 prefix。
2. `ArtifactCacheManager` 只负责 promoted immutable artifact，不提供 partial capability，也不承担 mutable download lifecycle。
3. 只有 session 真正 dispose/evict 时，`PartialDownloadHandoff` 才把 unfinished authoritative prefix 交给 `PersistentChapterDownloadService` 的 `PartialDownloadStore`；新 session 在 origin open 前按精确 DownloadId 恢复。它是 cold durability，不是热 reentry 主路径。
4. dev.205 cursor-reentry 顺序保留。约30帧 partial loop/waterline只属于 DecodeSession/playback；它可消费 DownloadSession 提供的 partial，却不得决定 persistence、resume/admission、cache identity 或 Download owner。
5. Venera JS/Kotlin继续拥有同步 bridge contract、Cookie、manual redirect、`cache-time`、`prevent-parallel`、requestId grouping与runtime cache。实际 HTTP execution迁到 isolated plugin Dart process 中 reusable rhttp/reqwest resolver client；Kotlin不得再创建 `HttpURLConnection`、DoH client或reflective OkHttp fallback。
6. requestId cancellation映射到 rhttp `CancelToken`；manual redirect仍在 Kotlin semantics层逐跳执行，因此跨 origin移除Authorization/Cookie等既有规则保持。
7. 主 App final-media rhttp 与 isolated plugin resolver rhttp 位于不同进程，不能共享同一物理 client/pool；要求统一的是 client family 与连接生命周期 owner，而不是跨进程 singleton。

## 风险边界

MethodChannel只承载 resolver `Network.*` 的受限 response body，不承载普通漫画图片正文；普通 page body仍走 source-resolved streaming transport。不能为了“统一 client”把 resolver HTTP 纳入 NetLane 第二调度器，也不能把约30帧循环条件下沉到 Download/Artifact cache。
