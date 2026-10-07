# dev.320 high-performance vertical scene-motion audit

## Input and device identity
Input: `zic-debug-trace-2026-08-19T23-59-41.jsonl`, explicitly identified by the user as the high-performance device. Do not merge its cadence fingerprint with the low-performance/effective-60Hz traces.

## Frame supply and Reader motion are already healthy
Across nine `platformFrameCadenceSummary` windows there are 2,064 Android Choreographer intervals: 2,052 <10ms, 8 at 14–18ms, one at 20–25ms and three >=35ms; weighted mean is 8.419ms and display refresh is 120Hz. Across 22 `scrollCadenceSummary` windows there are 2,047 non-zero ScrollUpdate intervals: 1,989 <10ms, 38 at 10–14ms, 13 at 14–18ms and seven at 18–20ms; none are >=20ms. Drag contributes 374 and ballistic 1,673. Flutter FrameTiming is likewise dominated by ~8.318–8.319ms cadence with small Build/Layout/Paint/raster phases. Sparse ~25/40/58ms holes exist but cannot account for frequent mild visible stutter.

This falsifies the idea that the high-performance device's remaining stutter is explained by a healthy 120Hz app frame stream being reduced to ~60Hz by Reader ScrollPosition updates. It also makes ordinary framework phase over-budget work a poor common explanation.

## dev.319 Window FrameMetrics coverage is insufficient
Only 62 Window FrameMetrics are summarized. Eight `platformWindowFrameMetricsOutlier` exports collapse to four unique `vsyncNanos` values; the duplicated pairs have identical metrics. The unique mapped timestamps are approximately 3.075s, 3.092s, 3.150s and 3.217s, while the first active Reader scroll observation occurs at about 3.793s. Their large `UNKNOWN_DELAY_DURATION` therefore describes startup Window/ViewRoot frames, not the ongoing scrolling interval.

The dev.319 analyzer verdict `android-window-ui-availability-delay-candidate` was too broad because it did not test coverage against active scrolling. dev.320 corrects the diagnostic by deduplicating identical vsync callbacks and exposing first/last Window-vsync coverage; Window metrics remain supplemental rather than a causal owner.

## Next discriminating observation
At each actual Flutter post-frame during active vertical scrolling, measure the final live scroll pixels and current page RenderBox global top. `globalTop + pixels - expectedStart` cancels ordinary list translation and should remain constant across frames and page seams when the scene follows ScrollPosition correctly. Aggregate this without scheduling new frames.

A dev.320 device run must be interpreted before introducing another behavior experiment. If residual continuity fails, investigate Flutter scene/sliver transform timing. If scene continuity is healthy while the user still sees the same stutter, stop modifying Reader/Flutter framework behavior and move to actual display presentation with Perfetto/SurfaceFlinger (or a verified platform compositor-jank API when device/API support permits).
