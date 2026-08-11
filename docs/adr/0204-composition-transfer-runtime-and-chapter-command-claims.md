# ADR 0204：Composition transfer runtime 与章节命令 claim 迁移

- 状态：Accepted
- 日期：2026-08-11

## 背景

Reader 在 dev.216–222 已逐步把 exact `DownloadId` 的 writer、network task、retry、hot partial 与 scoped demand 提升到 composition physical owner；但 `PersistentChapterDownloadService` 仍创建自己的 `DownloadRegistry/DownloadJob`，于是“显式下载章节”仍同时是 command 与第二个网络下载 owner。`WholeComicDownloadQueue`虽然只聚合章节任务，也因此间接触发另一套 physical transfer。

另一个历史耦合是 persistent chapter service 同时承担 command、durable artifact backend、partial store 与 maintenance。若直接把 Reader runtime 注入该 service，会形成 `command/store -> physical runtime -> artifact/partial backend -> command/store` 的循环 ownership。

## 决策

1. 将 dev.216 起的 composition physical runtime 从 `pipeline_runtime` 私有实现提升到 `downloads` 公共的 `CompositionDownloadTransferRuntime`。它拥有 exact `DownloadId` 的 `DownloadRegistry`、`DownloadTransferOwner`、NetLane 任务、hot workspace、artifact/partial handoff；Reader 不再创建或拥有该 runtime，只 attach consumer。
2. physical owner 的 consumer API 使用 policy-neutral `TransferDemand`。Reader 在 `LiveCoordinator` 边界把 `DownloadDemand` 映射为 transfer claim；physical owner不认识 `PageRole/current/next`。
3. `TransferDemand`同时携带 priority、reason、可选 checksum 与 completion intent。priority决定竞争顺序；completion intent决定是否属于“机会性可放弃”还是“低优先级但必须最终完成”。显式章节命令使用 `TransferCompletionIntent.required`，不得因为priority低而被Reader的costly full-body catch-up门槛永久defer。
4. 拆出 `PersistentDownloadArtifactStore`，只拥有 SQLite/files、promoted artifact、cold partial 与 maintenance。其内部 session/job仅用于把**已经完成的 immutable bytes**写入durable布局，不负责source/network transfer。
5. 新增 `PersistentDownloadComposition` 作为应用级生命周期 owner，持有唯一 durable store、`ArtifactCacheManager`、`CompositionDownloadTransferRuntime` 与 chapter command。生产 App 创建/关闭 composition；chapter command 本身不拥有 runtime/store 生命周期。
6. `ManagedChapterDownloadService`缩回 command-only contract。Persistent 实现暂时保留 artifact/partial/provider 委托 capability 作为 standalone/test兼容层，但生产 wiring 不依赖这些委托。
7. 章节下载逐页 attach `chapter-command:<identity>` consumer claim；取消仅撤销该 command scope。若 Reader 同时 demand 同一 exact `DownloadId`，只存在一个 physical session/writer/request。章节页只有在 physical session promoted **且** promoted bytes 已 handoff 到唯一 durable store 的该页exact `DownloadId` 后才记为 command complete；Reader可用verified alias满足读取不等价于显式offline command已完成exact durable materialization。
8. 多 consumer 的非空 expected checksum 必须一致，冲突在修改 claims 前原子拒绝。checksum 验证由单一 physical transfer执行一次。
9. Whole-comic 继续只聚合 `ChapterDownloadService`；不得新增 `DownloadRegistry/DownloadJob/Transport` owner。
10. `durableImmutable`只说明encoded body可resident消费，不说明durable cache已拥有正文。`ByteResponseBodyAuthority`显式区分source与artifact-cache authority；`DownloadSession`生产语义使用`residentBodyBacked/residentBodyAuthority`，旧`residentCacheBacked`仅保留兼容。source-resident promotion不会自动写cache；显式required-completion通过composition owner从当前consumer/source authority严格重放并验证length/validators，再materialize到唯一ArtifactCacheManager/store。

## 非目标

- 本 ADR 不实现 cross-version verified TransferKey-before-acquire；共享范围仍严格是 exact `DownloadId`。
- 不删除 dev.205–213 的 verified equivalence、durable partial、late takeover 等兼容路径；要等 TransferKey 与所有 consumer coverage完成后再逐项删除。
- 不把 decode/upload/presentation 提升到 composition；这些仍是 Reader-local。

## 后果

- “谁需要图片”与“谁拥有图片传输”进一步分离：Reader current/prefetch、章节命令、整本命令都成为 claim/aggregation。
- durable store 与 command 生命周期解环；App shutdown顺序必须先释放 retained Reader consumers，再关闭 composition runtime，最后关闭 store。
- completion intent 成为组合语义的一部分，避免用priority错误代替“是否必须最终完成”。
- immutability与durable body ownership成为两个正交事实，避免`residentCacheBacked`再次把source replay与cache authority混为一谈。
