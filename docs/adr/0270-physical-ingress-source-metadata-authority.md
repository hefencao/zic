# ADR 0270：source metadata 归 physical ingress authority

状态：Accepted（dev.291）

## 背景

dev.290 要求 Reader 页面几何最终以 source canvas 为权威，但 03:30 真机 Trace 中 12 次尺寸投影全部仍为 decoded-raster fallback。设备同时证明 future page geometry 通常已早于 current，因此继续扩大预解码窗口没有依据。

源码审计发现 dev.290 从 `DownloadSession.artifact.readPrefix()` 解析 source canvas；`PipelinePageStream.readPrefix()` 也使用同一路径。对 `residentBodyBacked` / artifact-cache resident physical session，正文权威由外部 immutable replay owner 提供，session Artifact 按设计可以为空。Pipeline 因而绕过了真实 encoded ingress owner。

## 决策

1. `DownloadSession` 每个 physical generation 最多保留 64 bytes 的 generation-local source-metadata prefix；它只用于类型/source canvas 等小型 metadata，不是正文缓存或正文副本。
2. prefix 随 authoritative ingress 从 offset 0 单调填充；restore 可从 session Artifact 恢复该小 prefix，resident-cache replay则直接从进入 session 的真实 bytes 填充。
3. WebP source canvas 在 sessions owner 内解析，并以 `DownloadSnapshot.sourceCanvasWidth/sourceCanvasHeight` 只读投影。
4. `PipelinePageStream.readPrefix()`只能调用`DownloadSession.readSourcePrefix()`，由session按resident body authority选择generation-local prefix、external replay或ordinary Artifact；Pipeline dimension resolution 只能消费 snapshot source canvas，不得自行选择 Artifact/cache/source backend。
5. dev.290 的 sourceCanvas > decodedRaster authority 保留；其 direct Artifact prefix 实现被本 ADR supersede。
6. Reader previous3/next7、decode previous1/next2、NetLane、texture、retention策略不变。

## 可证伪判据

下一份设备 Trace 中 artifact-cache resident WebP imminent page 应出现 `pageDimensionsResolved source=physical-ingress-source-canvas`。若仍全部 raster fallback，继续查 physical ingress prefix/identity；若 source canvas 已提前命中但视觉尺度仍异常，冻结预解码/source metadata线并转查实际 Sliver layout/item extent 与 output projection。
