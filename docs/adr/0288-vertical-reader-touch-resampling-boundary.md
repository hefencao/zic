# ADR 0288: Vertical Reader touch-resampling boundary

## Status

Superseded by dev.310. The dev.309 experiment remains historical evidence, but the 08:20 device Trace shows 20/22 cadence outliers are `dragDriven=false` ballistic updates after finger lift, so touch resampling is not the main owner and its production lease is removed.

## Evidence

- `scrollCadenceOutlier`: 49 non-zero vertical updates above 20ms; median 31.775ms, p90 36.668ms, max 75.923ms.
- The outliers are not dominated by known Reader/Pipeline work: only 16/49 are within ±20ms of `pipelineReconcileTiming` and 6/49 within ±20ms of `framePipelineTiming`.
- `readerFrameTiming` also contains repeated ~30–36ms intervals while build/raster/vsync overhead are often only ~1–3ms. The missing intermediate update/frame therefore cannot be explained by a normal over-budget Flutter build alone.
- dev.308 local-image preparation is mechanically healthy in this Trace: page19 firstFrameReady precedes first transition by about 963ms and page20 by about 764ms; sampled page extents no longer change from provisional to measured values.

## Decision

Flutter touch resampling is a framework/platform input concern. `reader` MUST NOT import or mutate `GestureBinding`. `reader_runtime` MAY acquire a process-global, reference-counted `FlutterReaderTouchResamplingLease` while a vertical continuous Reader is mounted. The first lease remembers the pre-existing `GestureBinding.resamplingEnabled` value and enables it; the final release restores that prior value. Horizontal/discrete Reader modes do not own a lease.

Use Flutter's built-in resampler only. dev.309 MUST NOT tune `samplingOffset`, synthesize pointer positions, add a custom Ticker/AnimationController, force frames, or alter ScrollPhysics. This preserves a single owner for scroll position and makes the experiment falsifiable.

`ScrollUpdateNotification.dragDetails` is the source-of-truth distinction between drag-driven and non-drag updates. Reader preserves `Interaction.dragging` when drag details exist and adds `dragDriven` to `scrollCadenceOutlier`. Pipeline's vertical active control class already groups dragging/scrolling/settling, so this diagnostic correction does not widen resource scheduling semantics.

## Falsification

- If `dragDriven=true` cadence outliers collapse and visible jitter improves, touch input/display frequency mismatch is a causal component.
- If outliers remain primarily `dragDriven=false`, freeze touch resampling and inspect ballistic `ScrollActivity` / Flutter engine / Android frame scheduling.
- If `dragDriven=true` remains around 25–35ms despite resampling, the next owner is platform/engine input delivery; do not add application-side interpolation.
