# dev.311 Reader Flutter-image presentation audit

## Baseline and trigger

- Unique code baseline: `zic_v0.31.0-dev.310_ballistic-platform-frame-cadence-boundary.zip`.
- Device Trace: `zic-debug-trace-2026-08-19T08-58-22.jsonl`.
- User control: VibeVenera does not reproduce the same continuous finger-lift jitter; old 2023 Flutter issues are therefore not treated as root-cause evidence.

## Trace result

The run contains 53 scroll cadence outliers: 38 ballistic and 15 drag-driven. Ballistic gaps are 20.334–45.979ms, median 27.4165ms. It also contains 58 Android cadence outliers. System-frame-gap median is 24.2205ms and max 66.309ms; callback-gap median is 24.2435ms and max 69.339ms. Most samples are actual Choreographer frame-time skips rather than only a late callback queue: 39 have both system and callback gap >=20ms with callback lag <8ms, six have system gap >=20ms alone, and only one sample combines callback lag >=8ms with no system gap >=20ms.

A frame-start/ScrollUpdate phase correction aligns a substantial subset of the 38 ballistic outliers with the same platform misses. Conversely, overlap against traced app work is sparse: only about 5/58 platform miss intervals intersect native decode, 3/58 presentation, 1/58 output preparation and 4/58 reconcile. This does not support expanding Reader/Pipeline control-plane micro-optimization as the unified cause.

All 40 recorded `framePipelineTiming` samples use `renderer=androidTexture`, while the pages classified in this run are authoritative single-frame static pages (`animated=false`, `frameCount=1`). Thus ZIC keeps multiple external SurfaceProducer page surfaces in the continuous scene even though no animation requires that topology.

## VibeVenera comparison

Current Venera reader source uses `ScrollablePositionedList.builder` for continuous mode and builds each item as `ComicImage` from an `ImageProvider`. `ComicImage` is explicitly derived from Flutter `Image` and keeps an `ImageStream` / `ImageInfo`. No `Texture` widget appears in that continuous item path. This makes the renderer topology a direct project-level difference worth removing before attributing the symptom to Flutter itself.

## dev.311 change

`NativePipelineMediaRuntimeFactory()` no longer creates an Android texture presenter/pool. Native download/source/cursor/libwebp decoding remains unchanged; the already-existing `_FlutterImageUploader` copies the decoded RGBA once into a Flutter `ui.Image`, `_FlutterOutputProjector` exposes it as an opaque Pipeline surface, and Presentation renders it with `RawImage`.

The former external-texture route is retained only through explicit `NativePipelineMediaRuntimeFactory.platformTexture()`. Production App Reader composition continues to instantiate the no-argument factory, so the experiment cannot silently fall back to SurfaceProducer. Standalone `NativeWebpPlayer` texture behavior is untouched.

## Frozen / next proof

Do not change touch resampling, ScrollPhysics, geometry/sourceCanvas, 3/7, decode 2/1, NetLane, current±2 static continuity or local-static pre-presentation. The next device proof must first show `renderer=flutterImage`, then compare ballistic and platform cadence on the same reproduction. A negative result closes this renderer-topology route and triggers Android System Trace rather than another speculative Reader tweak.
