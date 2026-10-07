# dev.318 static WebP composition audit

## Evidence entering the experiment
- High-performance trace: `zic-debug-trace-2026-08-19T15-16-15.jsonl`, explicitly identified by the user.
- Android Choreographer: 4,772 intervals; 4,761 below 10ms (99.77%); display rate 120,000 mHz; only three >=35ms gaps; max 74.870ms.
- Flutter timing summaries: 4,656 represented samples, approximately 8.319ms cadence. The few >=20ms raw intervals are too sparse to explain frequent mild subjective stutter, and most have cheap build/raster phases.
- The companion 15:15 trace is intentionally not assigned a device identity by this audit. It contains rare roughly 70–83ms platform/cadence holes with cheap framework phases; treat them as a separate sporadic component.
- User reports dev.317 removed the low-performance device's former frequent ~20ms UI jank, so its `Timer.run` observation boundary stays.

## Source comparison
Canonical source is the Library `vibevenera-master.zip`, not a web reconstruction. Its reader uses `ReaderImageProvider` for ordinary static images and reserves streaming/native Texture presentation for explicitly animated GIF/WebP. Its native texture path still performs the final native RGBA-to-ANativeWindow copy; “zero-copy” primarily removes Dart/cross-channel full-frame pixel copies. Therefore dev.318 does not treat the existence of one native blit as a bug. It tests whether keeping static pages as external Texture layers affects visible continuous-scroll composition even when frame cadence is healthy.

## Intervention
- Retain Pipeline demand planning, exactly-one-current-per-lane, native decode/upload, SurfaceProducer, texture lease and dev.313 local-static pre-presentation.
- Retain dev.317 observation `Timer.run`; no 180ms debounce.
- After authoritative `frameCount=1 && complete`, read the existing artifact's compressed WebP bytes through the Pipeline-injected bytes loader.
- Build `MemoryImage`/`ResizeImage`; continue drawing the existing Texture until Flutter's first image frame; then switch only visual presentation.
- Record `staticFlutterPresentation(route=pipeline-texture-fallback-to-compressed-flutter-image, textureRetained=true)`.
- Animated WebP remains native Texture.

## Next-run interpretation
Run `python3 tool/analyze_composition_motion_jank.py TRACE.jsonl`. The static chapter should show `static_flutter_presentations > 0` and `task_failed=0`. Compare `scrollCadenceSummary`: mostly `<10ms` on the high device means scroll motion itself is 120Hz; mostly `14-18ms` means motion updates are effectively ~60Hz even though engine/platform frames are ~120Hz. If the static projection occurs and both platform and scroll cadence are healthy but subjective jitter does not improve, this composition hypothesis is falsified.
