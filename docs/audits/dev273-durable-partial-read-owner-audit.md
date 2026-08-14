# dev.273 durable partial read owner 审计

## 设备证据
03:33 dev.272 Trace 共8415条事件。`physical-local-prepare`共60次；其中58次旧`local-hydration-ready`实际为`committedLength=0 / networkAdmissionRequired=true`，prepare中位约87.0ms、最大约124.9ms，本轮没有真正命中cold partial restore。43次origin `sourceRead` 的 `verifiedEquivalentCandidates` 均为4，因此exact miss后还会继续检查多个等价候选。

## 根因
`PersistentDownloadArtifactStore.openPartialDownload()` 是read/existence API，却通过 `_registry.get(id)` materialize durable-store `DownloadSession`，随后调用 `session.restore()`。dev.272把local prepare前移后，这个read-side session owner会在每个fresh physical identity、以及每个verified-equivalent candidate上提前运行。其职责与composition `DownloadTransferOwner`拥有的Reader physical session重复。

## 修复
- partial read改为SQLite index/file直接authority；hit/miss均不materialize store session。
- indexed file length与record一致才返回；resume `.meta` 直接解析，损坏metadata只丢resume knowledge，明确wrong owner才移除stale index。
- 读取成功touch既有index LRU；实际bytes继续由dev.272共享`ArtifactCacheReadScheduler`调度。
- Trace把无local bytes改名`local-hydration-miss`，避免把preflight miss伪装成hydration success。
- partial write path不改：mutation仍可通过store session/writer落盘。

## 排除项
不提高partial优先级、不增加local scheduler、不缩3/7、不改network 5+1、不修改Decode/Upload/SourcePool。
