# dev.310 Ballistic platform frame-cadence audit

## Baseline and trigger

- Unique baseline: formal `zic_v0.31.0-dev.309_vertical-touch-resampling-cadence.zip`.
- Device Trace: `zic-debug-trace-2026-08-19T08-20-10.jsonl`.
- User correction: strong jitter remains during fast-scroll ballistic motion after the finger has left the screen.

## Device result

There are 22 `scrollCadenceOutlier` events: only 2 are drag-driven and 20 are `dragDriven=false`. Ballistic gaps are 20.065–42.888ms with median 28.2005ms. Median absolute pixel delta is about 56.29px; large examples such as 30.367ms/+71.46px, 28.647ms/+106.41px and 42.888ms/-162.61px continue the inertial trajectory rather than proving a discontinuous position mutation.

`readerFrameTiming` independently contains multiple 30–42ms intervals with build/raster/total-span only a few milliseconds. Several ballistic outliers have no nearby policy/reconcile/texture/page-host event. dev.309 touch resampling is therefore falsified as the main route and must not remain as an unexplained global input mutation.

## Source boundary

Flutter ballistic ScrollActivity is frame-driven, but existing app Trace cannot distinguish a missing Android/Choreographer delivery from a Flutter engine frame-pipeline miss. App-side interpolation or ScrollPhysics tuning would hide rather than identify that boundary.

## dev.310 change

- Remove `FlutterReaderTouchResampling` production/test code and all `GestureBinding.resamplingEnabled` mutations. Keep `dragDriven`.
- Register a `reader_runtime` Android plugin using `Choreographer.FrameCallback`. Native work is bounded to integer timestamp arithmetic and an outlier-only 256-entry ring.
- Drain through MethodChannel every 2s, map `frameTimeNanos` against native/Dart monotonic anchors, and emit `platformFrameCadenceOutlier` without scheduling a Flutter frame.
- Start only for vertical Reader lifecycle; stop/drain on direction exit or dispose.

## Frozen

No Reader geometry, ScrollPhysics, Pipeline policy, 3/7 encoded window, decode 2/1 window, NetLane, local-static pre-presentation, sourceCanvas or texture behavior changes in this round.
