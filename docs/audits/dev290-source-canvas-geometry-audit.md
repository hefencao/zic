# dev.290 Source-canvas geometry audit

## 触发

用户在 dev.289 本地构建后继续报告纵排尺度在滚动中不正常，并询问是否因为预解码窗口不足；设备 Trace 为 `zic-debug-trace-2026-08-15T02-30-48.jsonl`。

## Trace 结论

本样本不支持“decode 2/1 不足”作为主要根因：page22–27 的 `pageDimensionsResolved/pageGeometryPrepared` 均在进入 viewport/current 之前完成，提前量约 0.4–3 秒；page27 已完成 geometry preparation 但样本内甚至尚未成为 current。继续扩大 decode window 只会增加资源和并发压力。

Trace 中 `pageDimensionsResolved` 的尺寸为 688×2312、592×2312、648×2328、928×2248、608×2232 等 decoder target raster。它们来自 `DecodeSnapshot.decodedWidth/decodedHeight`，而不是 source canvas。dev.287 因而修对了时机，却把 renderer raster 当成了 page geometry authority。

源码进一步发现 `parseWebpPrefixInfo()` 的注释声称“不要求完整 RIFF”，但实现先执行 `dataEnd > bytes.length -> null`；对 VP8/VP8L 而言，chunk length 是整个压缩图像大小，导致源宽高必须等几乎整个 chunk 到齐，尽管 width/height 实际位于 chunk 起始固定 header 中。

另一个 authority 泄漏是 `LocalImagePlayer`：Pipeline output surface 会以 `authoritative:false` 调 `_reportDimensions()`，但旧实现仍会调用 `onDimensionsChanged`，从而把 presentation raster 再次送进 Reader geometry。

## dev.290 收口

- 修正 WebP prefix parser，使 VP8X/VP8/VP8L 在固定 header 可用时立即读出 source canvas。
- Pipeline dimension feed 新增 sourceCanvas/decodedRaster basis；decode callback 优先 manifest/source-prefix，raster 只作为 provisional fallback，且不能覆盖已知 source canvas。
- ReaderRuntime 按 basis 维护唯一 aspect authority；source 可升级 raster，raster 不得覆盖 source 或 manifest intrinsic geometry。
- LocalImagePlayer 的 non-authoritative surface dimensions 不再逃逸到 Reader geometry callback。
- 保持 previous1/next2 decode、previous3/next7 encoded、network5、decode concurrency3、upload2 不变。

## 可证伪判据

下一份真机 Trace：
1. imminent pages 应在 `pageCurrent` 前得到 `pageDimensionsResolved`；
2. 优先应为 `basis=sourceCanvas`，source 为 manifest/prefix，而不是 `decode-raster-fallback`；
3. 如果 source-canvas 已提前进入 geometry 仍发生尺度变化，则停止扩大/调整尺寸预解码，转查 Sliver item extent identity、PageAsset↔DecodeId 映射和 geometry cache；
4. fixed-region jitter 继续和本问题分离，按 dev.285 physical churn → Sliver/layout/compositor 路线验证。
