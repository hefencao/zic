# dev.296 Source-canvas presentation aspect 审计

## 触发
用户在dev.295后继续报告固定区域/滑动抖动，并提供`zic-debug-trace-2026-08-15T08-43-56.jsonl`。明显缩放/比例异常早已解决，本轮不重新打开scale问题。

## 已冻结路线
Trace共105条`policyDecision`，其中89条dragging/scrolling/settling active vertical decision全部`staticWarmUploads=0`；dev.295 hidden speculative static upload已机械命中。320 条 `pageLayoutSnapshot`全部`extentDeltaPx=0`，2x2 transform均为identity，修正后的`layoutResidualPx`从头到尾固定`35.55555555555475`，因此Sliver/item extent没有支持抖动假设。retained static role重投影继续是zero-copy resident reuse。

## 新事实
`pageDimensionsResolved`显示Reader geometry使用physical sourceCanvas，但decoded native target存在独立rounding：page14 source `960x1950`、decoded `952x1936`，相对aspect约+0.116354%，在1080 physical-pixel fitWidth下尾缘约+2.5525px；page17约-1.25px，page10/11/13/15另有约0.27–0.72px差。

源码中`LocalImagePlayer`此前从output surface调用non-authoritative `_reportDimensions(surface.width, surface.height)`；它不会污染Reader geometry，但在sourceCanvas没有进入该presentation对象时，`MediaAspectViewport`仍以decoded raster比例建立media box，因此形成Reader page box与media box的双authority。

## dev.296 收口
- `PipelinePageStreamSnapshot`新增只读`sourceCanvasWidth/sourceCanvasHeight`，直接来自当前physical `DownloadSnapshot`。
- `LocalImagePlayer`监听page stream时优先把有效source canvas作为`authoritative: true` dimensions。
- 已有`_reportedDimensionsAuthoritative`合同保证后到decoded raster不能覆盖。
- 不修改Reader geometry、fitWidth算法、DecodeTarget、texture bridge/SurfaceProducer、resident reuse、3/7、decode2/1、NetLane或retention。

## 下一次设备判据
1. affected page的sourceCanvas必须真实投影到Presentation；decoded raster不能重新成为最终aspect owner。
2. dev.295的active `staticWarmUploads=0`和dev.294稳定layout判据继续保持。
3. 若固定边界抖动消失，则再以独立Trace复现确认；若仍在，冻结aspect路线，直接转external Texture subpixel layer/clip/compositor sampling。
