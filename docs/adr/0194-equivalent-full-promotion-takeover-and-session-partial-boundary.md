# ADR 0194：等价 Full Promotion Takeover 与 Session Partial 边界

状态：Accepted

## 背景

`zic-debug-trace-2026-08-11T03-35-42.jsonl` 是高频在 E-Hentai 同源版本间来回切换的压力样本。它同时出现多个371/377页 Reader session。dev.210–212 的 durable page mapping、verified-equivalence 与 durable partial均已工作，但仍存在：一个版本的页面正在 origin/partial 接收时，另一个已验证等价版本稍后完成 immutable full artifact，前者不会主动重新打开 ArtifactCacheTransport，因此继续把剩余尾部从 origin 下载。

对照 `vibevenera-master.zip`：VibeVenera 的 `CacheManager.aliasImage()` 在 `PipelineController._downloadIdentity()` 创建 `DownloadSession` 前解析 alias；同一 alias identity随后同时作为 `DownloadSessionRegistry`、`ImageDownloader._loadingImages` 与 `_PartialImageCache` 的key。因此它具有跨版本共享同一 in-flight/session partial 的**效果**，而不是额外执行“session partial迁移”。

ZIC当前每个 `PipelineReaderSession`拥有独立 `DownloadRegistry/SourcePool`，dev.206明确将hot partial限定为retained Reader session的单writer authority。直接把Vibe模式移植为跨Reader全局DownloadSession会同时改变取消、priority、retention、writer、Ingress/decode source生命周期，成本与风险远超过单纯缓存优化。

## 决策

1. 本轮不引入跨版本 hot/session partial共享，也不建立全局 DownloadSession alias/registry。
2. `ArtifactCacheManager.storePromotedArtifact()`在权威 backend commit + memory remember完成后发布只读 promotion事件。事件失败不得影响artifact commit。
3. 每个活跃 `PipelineReaderSession`只监听与自己 DownloadRegistry中已存在 DownloadId直接 verified-equivalent 的 promotion。若目标仍有demand、未promoted、不是cache-resident，则调用 `LiveCoordinator.refreshDownloadForLocalArtifact()`。
4. takeover只替换当前 network attempt：保留目标 `DownloadSession` 自己的 committed partial/Ingress，不reset、不复制hot writer。queued task重新排队；active task取消后依赖原finally在同demand下重新提交。下一次 `DownloadJob` open经 `ArtifactCacheTransport` exact-first/equivalent-second，从当前 committed boundary读取新出现的immutable full。
5. 新的local full事实可以清除当前DownloadId的network terminal/retry/defer记忆；这些记忆不得阻止已经本地可满足的demand。已经cache-resident的session不得被promotion事件重复抢占。
6. dev.212 mapping freshness真正过期时必须重新执行 strong page-identity验证并刷新 `verifiedAt`；“页数未变化”不足以把stale mapping重新判fresh。
7. origin trace增加 `verifiedEquivalentCandidates`，用于区分“该页没有mapping/equivalence边”“有等价候选但都没有full”和“已有full但takeover失效”。该字段只读，不得进入调度/cache/retry策略。
8. durable inactive partial跨版本复制规则保持dev.210：只经 `PartialDownloadStore`，清空跨版本validator，真实续传继续由DownloadJob overlap probe验证。

## 后果

- 覆盖“版本A仍在下载partial，版本B的同页稍后promote full，A继续origin”的浪费，而不建立跨Reader共享writer。
- 用户极端来回切版本时，两个Reader仍可能各自拥有hot partial；只有immutable full成为可复用事实后才允许跨session takeover。
- 若 trace显示 `verifiedEquivalentCandidates=0` 但最终两个版本下载出相同checksum，根因属于page mapping/offset覆盖而非session partial，本ADR不把该问题误判为下载session共享不足。
- 如果未来真实常规使用仍证明跨Reader in-flight共享收益显著，必须另立ADR设计composition-owned DownloadSession registry、取消/priority/retention与decode source绑定，不能在ArtifactCache或PartialDownloadStore里偷偷共享hot writer。
