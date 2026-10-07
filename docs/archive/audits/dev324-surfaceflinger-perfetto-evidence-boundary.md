# dev.324 SurfaceFlinger Perfetto evidence boundary

## Device evidence that closes dev.323 as sufficient root

The user reproduced the same fixed-position vertical continuous Reader hitch on the 05:33 dev.323 build. The run is valid: 1,743 trace events, 115 policy decisions, ten active direction flips, zero `taskFailed`, zero fixed-list failure, and no return of dev.320-style 5/5 download-window flips. Flip reconcile is 4.610ms median and 5.838ms max, below the 8.333ms 120Hz frame budget.

The dev.323 intervention itself fully worked. `tool/analyze_resident_static_reprojection_jank.py` reports `resident_static_represent total=0 associated=0 flip_exactly_two=0/10`, versus the dev.322 baseline of 52 associated repeated resident presentations and exactly two after every one of 26 flips. Because the visual hitch remains, retained-static re-presentation bookkeeping is not a sufficient root. The fast path remains a valid bounded optimization, but widening current±2 continuity or keepAlive would no longer be single-variable diagnosis.

## Remaining app-side evidence

`tool/analyze_composition_motion_jank.py` reports 2,487 Android cadence intervals, of which 2,480 are below 10ms at a reported 120Hz display rate. Flutter timing summaries cover 2,398 samples with a weighted 8.319ms interval. Four raw >=20ms Flutter intervals all have build and raster below 3ms and belong to startup/pre-active-scroll coverage rather than the repeated fixed-position motion.

`tool/analyze_vertical_scene_motion_jank.py` reports 2,190/2,190 valid vertical scene samples, 2,185 scene frame intervals, no missing RenderBox, no stationary ballistic sample and zero scene residual outlier. There is one raw 27.926ms ScrollUpdate gap in 2,378 intervals, but the sparse Android Window FrameMetrics capture has only 39 frames and its four unique outliers are all outside active scroll. Window FrameMetrics therefore cannot be promoted to a content-layer presentation proxy.

## dev.324 boundary

Do not change production Reader, Pipeline, role windows, geometry, physics, texture retention or download bridge behavior in this step. Capture the final Android graphics boundary instead. `tool/capture_reader_surfaceflinger_perfetto.sh` records Android 12+/API31+ `android.surfaceflinger.frametimeline`, active SurfaceFlinger layer snapshots with composition/HWC/buffer information, gfx/view/sched atrace for `dev.zic.zic`, scheduler events and process stats.

The matching offline analyzer reads `actual_frame_timeline_slice` for both the app and `/system/bin/surfaceflinger`, groups app frames by `layer_name`, computes gaps between actual presentation endpoints, and reports late-present, jank, late-finish, GPU-composition and fence-state evidence. This is intentionally observation-only and is not allowed to feed Reader/Pipeline policy.

## Next decision

1. If the reproduced hitch coincides with a ZIC Texture/content layer actual-present gap, late/jank tag, fence issue or SurfaceFlinger jank, continue below Flutter at buffer acquire/latch/present/composition.
2. If final FrameTimeline cadence is continuous and unjanky while the hitch remains visible, stop treating cadence as the primary hypothesis. Use the captured SurfaceFlinger layer snapshots to inspect layer transform/content transactions and device composition behavior around the repeated content position.
3. Do not restore already falsified touch resampling, forced frames, static Flutter projection, 180ms delay, physics tuning, current±7 presentation continuity or transport-quota tuning.
