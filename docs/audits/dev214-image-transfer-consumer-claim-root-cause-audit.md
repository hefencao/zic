# dev.214 Image Transfer Consumer Claim 根因审计

## 输入

- 唯一源码基线：`zic_v0.31.0-dev.213_equivalent-full-takeover-session-partial-boundary.zip`。
- 只读参考：文件库中的 `vibevenera-master(3).zip`（对应项目所称 `vibevenera-master.zip`）。
- 重点源码：`DownloadRegistry`、`DownloadSession`、`LiveCoordinator`、`DownloadJob`、
  `PipelineReaderSession`、`PersistentChapterDownloadService`、`WholeComicDownloadQueue`、
  `ArtifactCacheManager`、`PartialDownloadStore/Handoff`、version page mapping/reuse路径。

## 当前 owner 图

### Reader

`PipelineReaderSession` 每次创建：

- Reader-local `SourcePool`；
- Reader-local `DownloadRegistry`；
- Reader-local `DecodeRegistry` / `UploadRegistry`；
- Reader-local `LiveCoordinator`。

`LiveCoordinator` 不只是把 demand送入 registry，它还持有 `_networkTaskKeys`、retry、terminal
failure、deferred catch-up。因此 registry共享而 coordinator不共享会产生双 owner。

### DownloadSession

当前 session 同时持有：

- `Artifact`、writer、run lease、resume metadata；
- 单个 Reader native `Ingress`；
- source listeners；
- dev.213 的单一 `_demanded` bool。

其中 artifact/writer/run 属于 image transfer；单个 native `Ingress` 属于 Reader decode ingress。
两类状态混在一个对象里，是不能直接 globalize 的真正阻塞点。

### Chapter / whole comic

`PersistentChapterDownloadService.open()` 仍创建自己的 `DownloadRegistry`，章节命令逐页创建
`DownloadJob`；`WholeComicDownloadQueue` 再聚合 chapter service。因此它们目前仍是独立
physical session owner，而不是 demand aggregation。这是后续阶段必须迁移的 owner债务。

## VibeVenera 对照

实际源码确认：

1. `CacheManager.aliasImage()/resolveImageAlias()` 建立 logical image alias；
2. `PipelineController._downloadIdentity()` 在 session acquire **之前**解析 alias；
3. `DownloadSession.attach(scopeId, priority)` 返回 demand lease；
4. `desiredPriority` 取全部 demand 的最大值；
5. `detachScope()` 仅撤销 logical scope；
6. `_loadingImages`、`joinLoadingComicImage()` 与 `_PartialImageCache(cacheKey)` 使用同一 resolved
   cache identity共享 in-flight/partial。

因此 VibeVenera 的跨消费者共享不是“全局 Map”单点技巧，而是 identity-before-acquire +
claim lifecycle + physical owner三者共同成立。

## dev.214 最小安全切面

本轮选择先迁移 demand ownership：

- `DownloadSession`：单 bool -> scoped `DownloadDemandLease`；
- effective priority：max(claim priorities)，禁止累加；
- `LiveCoordinator`：每个 Reader session只持有自己的 claim；
- detach：先移除自己的 claim；仍有 claim 时不取消 active task，并降级到剩余 max priority；
- `DownloadJob`：新增显式 legacy-demand兼容开关，Reader path关闭，防止 claim被旧 attach污染。

这是真实产品路径修改，但故意不宣称完成了 cross-Reader transfer sharing。

## 为什么本轮不提升 registry

若现在把 `_downloads` 提升到 factory/global：

- A/B `LiveCoordinator` 都会对同一 `DownloadSession` 建立 task/retry状态；
- A dispose当前会 cancel它自己的 task，而该 task可能正是 B消费的唯一 writer；
- session只有一个 `Ingress`，其 `SourceFactory`来自创建该 Reader 的 `_media.sources`，B 的
  DecodeSession不能安全把它当成本 Reader native source；
- per-Reader ephemeral `CacheLayout` 也不是 composition transfer artifact的稳定根。

所以安全顺序必须是：claims -> ingress projection/physical transfer split -> composition registry +
retry owner -> verified TransferKey before acquire -> command aggregation。

## dev.205–213 补偿机制处置

| 能力 | dev.214 分类 | 理由 |
|---|---|---|
| VerifiedArtifactReusePlan | 保留 | 强证据复用与后续 TransferKey proof仍需要 |
| persisted page mapping | 保留 | verified equivalence的稳定输入 |
| verified equivalence registry | 保留 | immutable exact-first fallback仍正确 |
| durable partial copy | 兼容/保留 | 冷启动、进程边界仍需要 |
| session partial handoff | 暂时兼容 | hot partial转成 ImageTransfer state后再删 |
| artifact handoff | 保留 | immutable durable cache owner不变 |
| equivalent-full promotion takeover | 暂时兼容 | acquire前归一后可能部分删除 |
| retained DownloadSession | 暂时兼容 | Reader retention与transfer retention尚未拆开 |
| Reader-local DownloadRegistry | 待替换 | 当前仍受 native ingress/retry owner阻塞 |

## 下一阶段进入条件

在真正共享同一 active partial 前，至少需要：

1. neutral physical transfer state不再持有唯一 Reader native `Ingress`；
2. 每个 Reader可从同一 transfer committed prefix建立自己的 ingress projection；
3. network task/retry/terminal failure只有一个 composition transfer owner；
4. consumer detach只移除 claim，owner依据剩余 claim决定 priority/retain/cancel；
5. transfer workspace/artifact root不由任一 Reader route临时目录决定；
6. exact `DownloadId` 共享先成立，再把 verified version equivalence前移到 `TransferKey`。
