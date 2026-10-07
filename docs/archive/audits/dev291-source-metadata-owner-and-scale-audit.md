# dev.291 Source metadata owner / scale audit

## 触发

用户在 dev.290 真机继续报告滚动中的尺度异常；Trace 为 `zic-debug-trace-2026-08-15T03-30-38.jsonl`。

## 设备事实

- 12 次 `pageDimensionsResolved` 全部为 `basis=decodedRaster / source=decode-raster-fallback`，`sourceCanvas` 为 0。
- 多数后续页的 dimension/geometry fact 已在 `pageCurrent` 前约 0.4–10 秒存在；扩大 decode previous1/next2 无法解释该样本。
- source lifecycle 显示这些 WebP 多为 `residentBodyBacked=true`、`residentBodyAuthority=artifactCache`。

## 根因

dev.290 从 `download.artifact.readPrefix(64)`解析 source canvas，同时 `PipelinePageStream.readPrefix()`也直接读取 `session.artifact`。artifact-cache resident session 为避免正文重复，按架构允许 session Artifact 为空；真实 encoded bytes 从外部 immutable authority replay 进入 physical ingress。错误读取又被 raster fallback 吞掉，因此 source-canvas 设计在设备上从未命中。

## dev.291 收口

- DownloadSession 持有最大64-byte generation-local source-metadata prefix，并在真实 ingress 到达时解析 WebP source canvas。
- DownloadSnapshot只读暴露 source canvas；Pipeline 不再读取 Artifact 推断 storage owner。
- PipelinePageStream 的 prefix 读取同样统一到 physical ingress prefix。
- 正文不复制；网络/预解码/holder/texture/retention策略不变。

## 仍未宣称解决的部分

该 owner bug 是真实缺陷，但不能据此提前宣称视觉尺度问题已完全解决：本 Trace 中若干页面即使使用 provisional raster，geometry 也已明显提前且没有后续 ratio upgrade。下一Trace在 sourceCanvas 路径真实命中后，若仍异常，应直接记录/比较 source ratio、decoded surface ratio、Reader layout extent 和 current/transition projection，停止继续扩大预解码或增加视觉补偿。
