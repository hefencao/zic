# ADR 0251：durable partial read 使用 index/file authority

## 状态
Accepted in `0.31.0-dev.273`。

## 背景
03:33 dev.272 真机 Trace 中 physical local prepare 共 60 次，其中 58 次网络页 prepare 的 `committedLength=0`，中位约87ms、最大约125ms；43 次 origin `sourceRead` 均有4个 verified-equivalent candidates。源码审查发现 `PersistentDownloadArtifactStore.openPartialDownload()` 为回答“是否存在 cold partial”调用 `_registry.get(id) → DownloadSession.restore()`，而 `PartialDownloadHandoff` 又会对 exact 与 verified equivalents 逐一调用该 read API。结果是普通 local miss 也会 materialize durable-store synthetic session，并把 read/existence lookup 与 session lifecycle 绑定。

## 决策
- durable partial 的存在性与只读 bytes authority 是 persistent index + indexed file；read hit/miss不得创建 `DownloadSession`。
- `openPartialDownload()` 直接校验 index record、file length与resume metadata，并从 indexed partial file 分块读取。明确不同 DownloadId 的metadata使该stale record失效；缺失/损坏metadata只丢validators/total-length加速证据，不否定已索引media prefix。
- validators仅在其request URI与exact canonical URI一致时暴露；verified-equivalent restore继续由`PartialDownloadHandoff`清空validators。
- durable partial 写入/更新仍是mutation，可继续使用store内部受控session/writer；本ADR只删除read lookup反向创建session的owner重叠。
- dev.272 的pre-NetLane physical local prepare与唯一`ArtifactCacheReadScheduler`保持；无local state时应快速`local-hydration-miss`，只有真实命中才`local-hydration-ready`。

## 不变边界
previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1、transport/source lease、body-read permit、current抢占、Decode/Upload generation均不变。
