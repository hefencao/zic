# dev.223 章节下载 physical ownership 迁移根因审计

## 结论

dev.222 真机 Trace 已证明 slider scrub 分层工作：132 个 `interaction=scrubbing` plan 全部为1 download / 1 decode / 1 upload；未再出现 `decodeState=failed`、`sessionBusy/writerBusy` 或此前的resident late-join长黑页。因此本轮不再改Reader scrub、resident replay、NetLane或水位，而转向尚未迁移的显式章节/整本下载 physical owner。

## dev.222 源码 owner 图

```text
Reader/prefetch -> Composition physical runtime -> DownloadTransferOwner

PersistentChapterDownloadService
  -> own DownloadRegistry
  -> own DownloadJob
  -> source/network transfer
  -> 同时又是 ArtifactCacheBackend / PartialDownloadStore

WholeComicDownloadQueue -> ChapterDownloadService
```

这使同一 exact `DownloadId` 仍可能因为“Reader需要”与“章节命令需要”各自出现一条physical transfer；同时 command/store 合一阻止了直接共享runtime，因为会产生 durable backend依赖环。

## 迁移后的 owner 图

```text
PersistentDownloadComposition
  ├─ PersistentDownloadArtifactStore
  │    ├─ promoted immutable bytes
  │    └─ cold partial / maintenance
  ├─ ArtifactCacheManager
  ├─ CompositionDownloadTransferRuntime
  │    ├─ one DownloadRegistry
  │    ├─ one DownloadTransferOwner
  │    ├─ one NetLane task per exact DownloadId
  │    └─ hot partial / artifact handoff
  └─ PersistentChapterDownloadService (command only)

Reader current/prefetch ----- TransferDemand ----┐
Chapter command ------------ TransferDemand -----+--> same physical owner
Whole-comic --aggregate--> Chapter command ------┘
```

## 迁移中发现的额外语义缺口

最初将chapter command简单表示为`priority=120`是不充分的。现有full-body catch-up admission按Reader priority判断成本；一个已有>1MiB partial且server不支持Range的显式下载，会因为低priority被永久defer。显式下载的真实语义是“低优先级，但必须最终完成”，而prefetch是“低优先级、机会性”。因此physical claim新增completion intent，聚合时任一`required` consumer都允许该transfer在获得执行槽后完成catch-up；这不是chapter special case，而是consumer组合语义的必要维度。

## 迁移中发现的resident durable-completion缺口

继续审查显式chapter command的durable barrier时发现，历史`ByteResponseDisposition.durableImmutable`同时覆盖ArtifactCacheTransport命中与`file/content/asset`等可重开immutable source；旧`residentCacheBacked`因此错误地把“可resident且无需复制session artifact”解释成“ArtifactCacheManager已拥有正文”。这会让local immutable chapter physical session promoted后handoff直接skip，而durable store仍为空。dev.223将两件事拆开：response disposition只声明resident immutability，新增`ByteResponseBodyAuthority`声明正文authority；physical session生产路径迁移到`residentBodyBacked/residentBodyAuthority`。普通Reader source-resident只保留可重放状态，显式required-completion才通过composition `DownloadTransferOwner.openResidentReplay()`使用仍attached的consumer transport校验boundary/validators并materialize到唯一cache/store。这样Reader展示、physical promotion、offline durable completion成为三个独立事实。
此外，Reader cache satisfaction允许通过verified alias读取，但显式offline completion必须保证章节页exact `DownloadId`在durable backend可读；因此ArtifactCacheManager新增exact backend probe，required-completion barrier不会把“alias可读”误记为“exact offline artifact已落盘”。

## 兼容机制分类

- `VerifiedArtifactReusePlan`、persisted page mapping、verified equivalence：保留，后续作为TransferKey proof输入。
- durable partial store：保留，仍是cold/process-boundary owner。
- `PartialDownloadHandoff`：保留，physical runtime最后claim消失时仍需将hot partial转入cold store。
- `PromotedArtifactCacheHandoff`：保留，唯一durable artifact owner仍是ArtifactCacheManager/store。
- session partial handoff / equivalent-full takeover：暂时兼容；verified TransferKey-before-acquire覆盖后再评估删除。
- Reader-local physical runtime：dev.223正式删除/降级；Reader只attach public composition runtime。
- chapter-local network `DownloadRegistry/DownloadJob`：dev.223正式删除；store内部用于durable materialization的registry/job不是source/network owner。
- Persistent service 的cache/partial/provider接口：兼容委托，生产App不依赖；后续可在standalone callers迁移后删除。

## 未完成

1. verified relation/page mapping/strong media proof 尚未归一成 TransferKey-before-acquire；不同DownloadId即使已验证等价，active transfer仍不共享writer。
2. 需要完整Dart/Flutter工具链执行新增multi-consumer与chapter cancellation/catch-up行为测试。
3. 需真机同时触发Reader + explicit chapter download，确认同exact id只出现一次physical `downloadStarted`/transport open，取消章节不影响Reader current。
