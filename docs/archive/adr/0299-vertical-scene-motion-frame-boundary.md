# ADR 0299：Vertical scene-motion frame observation boundary

## 状态
Accepted as dev.320 observation-only diagnostic boundary; causal result pending device verification.

## Context
The 23:59 dev.319 trace is explicitly from the high-performance device. Android Choreographer supplies 2,064 intervals, 2,052 below 10ms, with mean 8.419ms. Reader records 2,047 non-zero ScrollUpdate intervals, 1,989 below 10ms, and Flutter FrameTiming is dominated by ~8.319ms frames whose Build/Layout/Paint/raster work is small. A few 25–58ms cadence holes exist but are too sparse to explain the user's frequent mild visible stutter. This removes frame supply, Reader-side 60Hz decimation and framework phase cost as good shared explanations.

dev.319 Window FrameMetrics cannot close the remaining gap: it reports only 62 Window frames and its eight exported outliers are four duplicate vsync callbacks, all before the first active scroll. The listener observes Window/ViewRoot work but is not a continuous proxy for Flutter SurfaceView content frames in this app.

## Decision
Keep production behavior unchanged from the beneficial dev.317 boundary: Reader observation drains on an ordinary event turn and static/animated WebP use the unified native-texture pipeline. During active vertical scrolling only, Reader recursively registers `addPostFrameCallback` without scheduling a frame. At each actual Flutter post-frame it reads the live `ScrollPosition.pixels`, resolves the current page through `ReaderVerticalGeometry`, reads that page's attached RenderBox global top, and computes `layoutResidual = globalTop + pixels - expectedStart`. The residual is invariant to ordinary scroll translation and remains comparable when current page identity crosses a seam.

The probe aggregates fixed cadence bins, moving/stationary sample counts, missing RenderBox samples, residual outlier count and max absolute residual delta into about-one-second `verticalSceneMotionSummary` records. Only >=20ms frame gaps or residual delta >0.25 logical px produce `verticalSceneMotionOutlier`. Both trace kinds are explicitly no-feedback: no `scheduleFrame`, `setState`, `jumpTo`, `animateTo`, geometry correction or policy input is allowed.

Window FrameMetrics remains supplemental observation. API26+ identical positive `vsyncNanos` callbacks are deduplicated and summary carries first/last vsync timestamps so sparse coverage is visible rather than silently treated as complete.

## Interpretation / stop conditions
- Repeated residual deltas while scroll pixels continue smoothly support a Flutter scene/sliver transform discontinuity below the existing coarse layout snapshots.
- Repeated active post-frame samples with unchanged pixels while Choreographer supplies fresh 120Hz frames support a Flutter scene-position repeat/stall boundary.
- Healthy 120Hz platform + ScrollUpdate + post-frame scene residual continuity with visible stutter closes the remaining Flutter framework/Reader motion route. The next owner must be actual presentation/composition; capture Perfetto/SurfaceFlinger rather than changing Reader policy.
- Do not respond by restoring 180ms debounce, touch resampling, app interpolation, physical-pixel snap, per-page RepaintBoundary, static Flutter projection, frame-rate policy or prefetch threshold tuning.
