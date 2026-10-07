# ADR 0297：Static WebP Flutter projection composition boundary

## 状态
Rejected / FALSIFIED by dev.319 device evidence; production projection rolled back, diagnostics retained.

## Context
The user explicitly identifies the 15:16 trace as the high-performance device. Android Choreographer records 4,761/4,772 intervals below 10ms at 120Hz and Flutter timing is centered near 8.319ms, while Build/Layout/Paint/raster are usually small. Subjective stutter nevertheless remains. dev.317 is retained because the user reports the low-performance device no longer has the former frequent ~20ms UI jank. Sparse 70–80ms cheap-phase holes remain a separate problem and are not used to explain the frequent high-device mild jitter.

The canonical Library `vibevenera-master.zip` is an architectural control: ordinary static reader images use `ReaderImageProvider`; explicitly animated GIF/WebP enters the streaming/native Texture route. dev.315 did not validly test this distinction because it removed static UploadDemand and produced 378 planner failures (`a plan must contain exactly one current demand per lane`).

## Decision
Keep the dev.317 ordinary-event-turn observation seam and keep Pipeline download/decode/upload/native SurfaceProducer behavior unchanged. When `PipelinePageOutputSnapshot` has a surface and authoritative animation truth is complete with one frame and zero duration, `LocalImagePlayer` may load the existing Pipeline artifact's compressed WebP bytes through the already-injected token loader and build a Flutter `MemoryImage`/`ResizeImage` projection. The existing Pipeline Texture remains visible until Flutter reports its first decoded image frame; only then does the page switch visual presentation. The Pipeline texture remains retained and animated WebP never enters this route.

This intentionally duplicates some static presentation residency during the experiment. It is preferred over changing resource ownership because it isolates compositor/presentation topology without violating the exactly-one-current-per-lane invariant. If device evidence supports the hypothesis, later memory optimization must be designed at an owner-correct Pipeline seam rather than by deleting Reader demand.

## Diagnostics and stop conditions
`staticFlutterPresentation` proves that the page actually switched to the compressed Flutter projection. `scrollCadenceSummary` separately measures real ScrollUpdate cadence. If high-device scroll intervals are mostly below 10ms and the projection improves subjective motion, static external-Texture composition gains causal support. If scroll intervals are instead mostly 14–18ms, investigate motion update cadence. If projection occurs, scroll cadence is below 10ms, and stutter is unchanged, falsify this route and do not revive dev.315 or a 180ms debounce.


## dev.319 reversal
The 16:22 dev.318 trace is a valid test rather than a planner-failure confound: all 11 authoritative classifications are one-frame static output, `staticFlutterPresentation` occurs 12 times and `taskFailed=0`, yet the user still reports the Reader problem. dev.319 therefore restores dev.317 native-texture presentation and keeps only the observation-only `scrollCadenceSummary`. This negative result does not restore dev.315 and does not imply that native Texture is itself the root; the next owner boundary is Android Window/frame-pipeline timing below the already-small Flutter framework phases.
