# dev.309 Scroll cadence / touch resampling audit

## Baseline and trigger

- Unique code baseline: formal `zic_v0.31.0-dev.308_local-static-prepresentation-reverse-geometry-preparation.zip`.
- Device Trace: `zic-debug-trace-2026-08-19T05-24-08.jsonl`.
- User report: strong vertical continuous jitter remains after dev.308.

## What dev.308 closed

The new Trace no longer supports reopening the local-image black-frame/reflow route. Every sampled local page with both events reaches `firstFrameReady` before its first transition; page19 is ready about 963ms early and page20 about 764ms early. Across 105 `pageLayoutSnapshot` events, a given sampled page no longer changes `expectedExtent` from a one-screen provisional value to a later measured value.

## Remaining device evidence

There are 49 exported `scrollCadenceOutlier` events, all above the existing 20ms threshold. Their gap distribution is min 20.052ms, median 31.775ms, p75 35.178ms, p90 36.668ms, p95 about 43.726ms and max 75.923ms. Pixel deltas are non-zero, so these are missing/late raw scroll updates rather than idle trace gaps.

`readerFrameTiming` independently shows repeated roughly 30–36ms frame intervals with cheap frame work. Representative samples have build/raster/vsync-overhead around 0.8–1.6ms / 1.0–2.7ms / 0.3–2.2ms. Only 16 of the 49 scroll-cadence outliers lie within ±20ms of `pipelineReconcileTiming`, and only 6 within ±20ms of `framePipelineTiming`. That is too weak to keep treating Pipeline/session/presentation work as the sole remaining explanation.

## Source audit

`ReaderView` currently resets `Interaction` to `scrolling` for every `ScrollUpdateNotification`, even when `dragDetails` is non-null. That makes the device evidence unable to distinguish a finger-driven low-cadence stream from ballistic scrolling.

Flutter exposes touch resampling on `GestureBinding`; it is process-global framework state. Therefore the production owner must be `reader_runtime`, not `reader`. A scoped, ref-counted lease is required so nested/overlapping Reader routes do not restore the global flag early and so the pre-existing value is restored after the final vertical Reader exits.

## dev.309 candidate

- Add `FlutterReaderTouchResampling` / lease in `reader_runtime` and enable `resamplingEnabled` only for the lifetime of a vertical continuous Reader.
- Re-sync the lease after every production `ReaderController.setDirection()` path and release it on dispose.
- Preserve `dragging` on drag-driven ScrollUpdate and record `dragDriven` in `scrollCadenceOutlier`.
- Do not modify `samplingOffset`; do not add custom interpolation, Ticker, forced frame scheduling, ScrollPhysics changes or resource-window changes.

This is device-informed but not yet device-verified. The next Trace must separate drag-driven and ballistic outliers before any further scrolling workaround is accepted.
