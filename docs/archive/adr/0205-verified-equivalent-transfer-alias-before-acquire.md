# ADR 0205：Verified equivalent physical transfer alias before acquire

- 状态：Accepted
- 日期：2026-08-11
- 2026-09-12：由 ADR 0310 细化。`DownloadId` 的 exact consumer/provider 语义、已有两个 live session 不做 late merge 的合同继续有效；“只能 alias 到既有 exact physical carrier”属于过渡实现，production 已改为 exact page 直接解析稳定 canonical `PhysicalMediaId`。

## 背景

dev.216–224 已把 Reader/prefetch/chapter/whole-comic 迁到同一个 composition physical owner，但共享仍严格按 exact `DownloadId`。dev.210–212 已有 source-confirmed relation、持久 page mapping 与 strong media identity 生成的 direct verified equivalence；dev.213 仍只能在另一个版本后来得到 full artifact 时做 late takeover，因此两个已验证等价版本若先后建立 session，仍可能各自创建 writer/network request。

## 决策

1. exact `DownloadId`继续属于consumer/cache/offline identity，不改写为跨版本canonical ID。
2. `DownloadRegistry`新增runtime-local physical alias，只允许在exact session尚未创建时绑定到一个已经存在的physical session；已有exact session绝不事后merge。
3. `CompositionDownloadTransferRuntime`在consumer acquire时使用`ArtifactCacheManager.directEquivalents()`作为proof输入。只有direct verified candidate唯一解析到一个已有且有active/committed/promoted authority的session时才alias；多个不同existing owners时保持exact分离。
4. source-resident且body authority不是`ArtifactCacheManager`的session不得跨版本join，因为它没有可独立重放的composition encoded body；普通hot/session artifact与artifact-cache resident body可以join。
5. `DownloadTransferOwner`内部按physical identity聚合claim，但每个claim保留exact `DownloadId`。真正source open、source bucket与provider diagnostics使用preferred claim的exact URI，而不是physical anchor URI。
6. 同一consumer若多个exact demand归一到同一physical transfer，priority取最高、required completion取OR、非空checksum必须一致。
7. chapter command必须先`replaceDemands`完成acquire-time identity resolution，再取得physical session。若exact B通过physical A完成，`persistPromoted(B)`必须先确保A durable，再基于本次verified physical alias复制/materialize B的exact durable artifact。
8. 现有equivalent-full promotion takeover、durable/session partial handoff暂保留，用于已有双session、cold restart partial与本阶段拒绝join的resident-source情况。

## 非目标

- 不做两个已存在hot session的merge。
- 不把direct verified equivalence递归扩成跨链canonical union。
- 不迁移cold partial到跨版本统一TransferKey。
- 不删除dev.205–213兼容路径。

## 后果

Phase C开始发生在physical acquire之前，但保持严格单调：只有“尚未拥有physical session”的exact identity可以加入已存在verified transfer。后续阶段必须用真机证明跨版本Reader/章节同时需求时只存在一次physical transport，并继续评估cold partial与兼容takeover删除条件。
