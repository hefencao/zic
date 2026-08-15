# ADR 0275：Source canvas 作为 presentation aspect authority

## 状态
Accepted。dev.296只统一已有physical source metadata在Presentation的只读消费，不新增geometry owner。

## 设备证据
08:43 dev.295 Trace已闭合hidden static upload与Sliver实际布局：89条active vertical policy全部`staticWarmUploads=0`；320条`pageLayoutSnapshot`全部`extentDeltaPx=0`、transform identity、修正后的residual恒定。剩余事实是source canvas与decoded raster并不总保持完全相同比例：page14为source `960x1950`、decoded `952x1936`，在1080px宽下fitWidth尾缘约差2.55px。

## 边界
`DownloadSession`/`DownloadSnapshot`继续唯一拥有physical source metadata。Reader geometry已经消费source canvas；若LocalImagePlayer再以decoded raster建立MediaAspectViewport，就形成第二套presentation aspect authority。decoded raster是native target rounding后的pixel carrier，不应反向定义媒体原始比例。

## 决策
1. `PipelinePageStreamSnapshot`只读投影当前bound physical generation的`sourceCanvasWidth/sourceCanvasHeight`。
2. `LocalImagePlayer`收到有效source canvas后以authoritative dimensions建立presentation aspect；后到decoded raster不得覆盖。
3. `MediaAspectViewport(fitWidth)`与Reader item extent因此消费同一source aspect，但仍由各自既有owner负责presentation和navigation/layout。
4. 不改Reader geometry/FittedBox、DecodeTarget、Android texture lease、SurfaceProducer/resident reuse、encoded 3/7、decode 2/1、NetLane或retention。

## 可证伪条件
若dev.296真机确认source/raster seam已消失而固定抖动仍在，则冻结本路线。下一阶段只查external Texture layer的subpixel placement、clip与SurfaceProducer compositor sampling，不再增加视觉补偿或第二套geometry。
