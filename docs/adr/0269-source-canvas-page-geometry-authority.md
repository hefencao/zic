# ADR 0269：页面几何只以 source canvas 为最终权威

状态：Accepted（dev.290）

## 背景

dev.287 把首个成功 decode 的 `decodedWidth/decodedHeight` 提前投影给纵向 Reader，解决了“尺寸事实到得太晚”的一部分问题。02:30 的 dev.289 设备 Trace 进一步否证了“预解码窗口不足”：page22–27 的 dimension/geometry preparation 普遍早于进入 viewport 约 0.4–3 秒，扩大 decode 2/1 不能解释仍存在的尺度变化。

问题在于 `decodedWidth/decodedHeight` 描述的是 decoder 为当前 target 生成的对齐/下采样 raster，而 Reader item extent 需要的是页面源文件的 canvas 几何。二者即使通常近似同比例，也不是同一个 authority；surface/output raster 更不能反向成为页面源几何。与此同时，`parseWebpPrefixInfo()` 对普通 VP8/VP8L 先要求整个压缩 image chunk 到齐，导致明明只需十几个 header byte 就能确定的源宽高被无谓推迟。

## 决策

1. `PipelinePageDimensions` 明确携带 `PipelinePageDimensionBasis.sourceCanvas | decodedRaster`。
2. 首个 decode 仍作为“现在值得解析 geometry”的时机，但 Pipeline 按以下顺序确定尺寸：
   - `PageAsset.width/height`；
   - 当前 physical artifact 的小型 WebP prefix（source canvas）；
   - 仅在源 canvas 仍不可得时，才使用 decoded raster 作为 provisional fallback。
3. `parseWebpPrefixInfo()` 对 VP8X/VP8/VP8L 只要求各自固定 header byte 可用，不再等待整个已声明 compressed chunk。
4. Pipeline dimension feed 一旦已有 `sourceCanvas`，后续 `decodedRaster` 不得降级覆盖。
5. ReaderRuntime 同样记录 geometry basis：source canvas 可升级 provisional raster；source canvas 已存在后 raster 不得覆盖；若 manifest 已给源宽高，raster 不得覆盖 manifest geometry。
6. `LocalImagePlayer` 的 surface/output width/height 只属于 presentation raster；`authoritative:false` 时不得再通过 `onDimensionsChanged` 逃逸为 Reader source geometry。header/source metadata 仍可上报。
7. 不扩大 Reader 预解码窗口：previous1/next2 decode、previous3/next7 encoded、并发和水位均保持冻结。

## 结果

Reader 的“何时知道尺寸”与“知道的是什么尺寸”被拆开：decode-ahead 保留其时序价值，但页面几何最终只认 source canvas。下一份设备 Trace 应优先出现 `pageDimensionsResolved` 的 `basis=sourceCanvas` / `source=webp-prefix-source-canvas|manifest-source-canvas`；如果大多数 imminent page 仍只能走 `decode-raster-fallback`，再查 source prefix/identity，而不是扩大 decode window。
