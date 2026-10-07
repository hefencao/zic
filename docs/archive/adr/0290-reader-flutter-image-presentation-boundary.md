# ADR 0290: Reader Flutter-image presentation boundary

## Status

Falsified by the 09:28 dev.311 device run; rolled back in dev.312.

## Evidence

The 08:58 dev.310 device Trace contains 53 `scrollCadenceOutlier` events, 38 of them `dragDriven=false` ballistic. Ballistic gaps are 20.334–45.979ms with a 27.4165ms median. The same run contains 58 `platformFrameCadenceOutlier` events: system-frame gaps reach 66.309ms, and 45/58 samples have a Choreographer frame-time gap >=20ms. After accounting for the expected frame-start to ScrollUpdate phase offset, many ballistic outliers align with the same platform cadence misses.

The miss intervals do not generally overlap the already traced Pipeline work: only a small minority overlap native decode, output presentation or reconcile intervals. The tested chapter is also authoritatively static (`frameCount=1`, `animated=false`) while every recorded `framePipelineTiming` uses `renderer=androidTexture`.

The VibeVenera control matters here. Its continuous reader uses `ScrollablePositionedList.builder` and ordinary `ComicImage(ImageProvider)` pages; `ComicImage` is derived from Flutter `Image` and owns `ImageStream`/`ImageInfo`. That is a materially different presentation topology from ZIC's one external Android SurfaceProducer texture per Pipeline page, so old generic Flutter frame-pacing reports are not accepted as the project root cause.

## Decision

Keep the native source/cursor/libwebp decode path, but make `NativePipelineMediaRuntimeFactory()` use the existing Flutter output path by default: decoded RGBA is converted once to `ui.Image`, projected through `_FlutterOutputProjector`, and rendered by `RawImage`.

Retain the SurfaceProducer implementation behind explicit `NativePipelineMediaRuntimeFactory.platformTexture()` opt-in for diagnostics/compatibility. Do not use that opt-in in normal Reader composition. The standalone `NativeWebpPlayer` remains independent and keeps its existing Android texture path when supported.

This change does not alter Reader geometry, ScrollPosition, ScrollPhysics, touch sampling, encoded 3/7, decode previous1/next2, NetLane, page-host retention or static pre-presentation eligibility.

## dev.311 device result

The 09:28 device run satisfies the experiment precondition: all 48 recorded `framePipelineTiming` samples use `renderer=flutterImage`. The symptom does not improve: 72 `scrollCadenceOutlier` events include 57 post-finger-lift ballistic gaps with median 28.194ms, while 87 `platformFrameCadenceOutlier` events include 70 Choreographer system-frame gaps >=20ms. Long `readerFrameTiming` intervals still have low build/raster cost, so moving static Reader presentation off SurfaceProducer does not close the cadence failure. The Flutter-image path additionally raises one-time `outputPrepareMicros` to roughly 31ms median in this run.

Therefore renderer topology is not the unified cause and production default returns to the pre-dev.311 Android texture presentation boundary in dev.312. This rollback is not evidence for texture correctness; dev.310 already reproduced the same ballistic problem on that path.

## Device falsification

On the next profile/device run, first confirm `framePipelineTiming.renderer=flutterImage` for the same local static chapter and that normal Reader presentation no longer emits platform texture present/blit work. Then reproduce the same finger-lift ballistic scroll and compare `scrollCadenceOutlier`, `readerFrameTiming`, and `platformFrameCadenceOutlier`.

- If ballistic/platform cadence misses collapse materially, the external SurfaceProducer page topology was a causal load/pacing contributor; keep Flutter-image Reader presentation and optimize one-time image conversion only if first-ready latency regresses.
- If Choreographer still drops at the same rate with `flutterImage`, the SurfaceProducer hypothesis is falsified. Freeze this route and capture Android System Trace around the remaining misses; do not restore texture presentation merely because the experiment is negative.
- If Choreographer becomes regular but Flutter/ScrollUpdate remains irregular, move to the engine/UI frame boundary with the platform side frozen.
