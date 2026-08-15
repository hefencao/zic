# dev.297 external Texture subpixel jitter 审计

## 触发
用户在dev.296后继续报告固定区域/滑动抖动，并提供`zic-debug-trace-2026-08-15T09-30-12.jsonl`。明显缩放异常已在dev.293后解决；dev.294–296只用于继续剥离抖动owner。

## 09:30 Trace 收口
- `pageDimensionsResolved`共8次，8/8为`basis=sourceCanvas / source=physical-ingress-source-canvas`。
- `pageLayoutSnapshot`共418条，418/418 `extentDeltaPx=0`；2x2 scale/shear均identity；`layoutResidualPx`只有一个值。
- dragging/scrolling/settling的active policy共92条，92/92 `staticWarmUploads=0`。
- `framePipelineTiming`共24条，其中19条`platformResidentReuse=true`，其platform blit/schedule/channel继续为0。

因此没有新证据恢复Sliver、hidden-static-upload、source/raster authority或resident-copy路线。

## 新事实：layout box整数，但Texture global edge为fractional physical pixel
对418条layout sample逐项乘以`devicePixelRatio=2.53125`：`renderWidth`与`renderHeight`全部落在整数physical pixel；`expectedStart`同样为整数physical pixel。可是continuous scroll的`scrollPixels * DPR`不是整数，因此414/418 `globalTop * DPR`带fractional phase，范围约`-0.4911..+0.4866px`，平均绝对phase约`0.2104px`。这意味着page geometry本身已经physical-pixel aligned，但每个external Texture composited layer仍会随scroll paint transform落到fractional device pixel。

sourceCanvas authority并不能消除最后的物理像素量化：1080px stitched宽度下，page13的source-aspect精确高度为1391.625px，而Reader item extent为1392px，残差0.375px；page14/15各约0.25px。dev.293正确禁止任意parent fill，但在dev.296统一source authority后，这一`<=0.5px`差异可明确识别为同源nearest-pixel rounding而不是未知geometry错误。

## dev.297 生产候选
- `MediaAspectViewport(fitWidth)`只有在parent height与source-aspect exact height差`<=0.5 physical px`时才直接填满rounded parent；真正大于半像素的mismatch仍使用top-aligned `FittedBox(fitWidth)`。
- 新增marker `PipelineExternalTextureSurface`，Android texture surface实现它；Flutter image surface不实现。
- external texture + fitWidth才包`PhysicalPixelAlignedPresentation`。其render object不改layout，只在physical-integral box与identity scale/shear时按当前global origin计算paint-time Y correction，最大绝对修正不超过0.5 physical pixel。
- 不改Reader ScrollPosition/physics/item extent，也不改3/7、decode2/1、NetLane、retention或resident frame reuse。

## 下一次设备判据
1. 缩放比例必须保持dev.293后的正确状态；任何明显stretch都视为dev.297阈值边界错误并回滚，而不是扩大阈值。
2. 同一固定边界慢拖/快速fling/ballistic/settling时抖动应显著下降或消失；资源窗口与resident reuse事实保持不变。
3. 若仍抖，停止Presentation几何补偿，转Flutter engine external Texture / SurfaceProducer sampling、crop和clip；不得量化ScrollPosition。
