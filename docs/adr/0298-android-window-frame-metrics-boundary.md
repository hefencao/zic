# ADR 0298：Android Window FrameMetrics observation boundary

## 状态
Accepted as dev.319 observation-only diagnostic boundary; causal result pending device verification.

## Context
The dev.318 16:22 device trace validly exercises the static Flutter projection: 11/11 authoritative classifications are `animated=false, frameCount=1, complete=true`, `staticFlutterPresentation` occurs 12 times and `taskFailed=0`. The user still reports the Reader problem, so the dev.318 visible static presentation experiment is falsified and must be rolled back instead of being optimized further.

The same trace separates motion cadence from Reader-side decimation. Across 2,006 non-zero ScrollUpdate intervals, 1,521 are 14–18ms. Across 2,205 Android Choreographer intervals, 2,096 are 14–18ms. Thus ScrollPosition motion tracks the app's delivered Choreographer cadence rather than silently updating only every second app frame. Ninety-seven platform cadence outliers have a 26.294ms median system gap; 76/97 spend less than half of that gap in Android main-thread CPU and 43/97 spend less than one quarter. Build/Layout/Paint/raster are likewise usually small. The remaining owner boundary is therefore below or around framework phases: Android Window/UI-thread availability, render sync/command issue/swap, or later display presentation.

The explicitly identified high-performance 15:16 trace remains a separate control: 4,761/4,772 Choreographer intervals are below 10ms with a mean near 8.37ms. dev.319 does not reinterpret the 16:22 effective-~60Hz signature as the shared root.

## Decision
Retain dev.317's latest-wins ordinary-event-turn observation drain because the user reports that it removed the low-performance device's former frequent ~20ms UI jank. Roll back only dev.318's static WebP Flutter projection to the dev.317 unified native-texture presentation path; retain `scrollCadenceSummary` because it is observation-only and has already separated Reader motion cadence from app Choreographer cadence.

While the vertical Reader's existing Android cadence probe is active, `reader_runtime` attaches `Window.OnFrameMetricsAvailableListener` on API 24+. The listener is delivered on a dedicated `HandlerThread("zic-reader-window-metrics")`, aggregates bounded timing data and never requests a Flutter frame or changes Reader/Pipeline behavior. It records `TOTAL_DURATION`, `UNKNOWN_DELAY_DURATION`, input, animation, layout/measure, draw, sync, command-issue and swap-buffer durations. API 26+ also records intended/actual vsync timestamps. Display refresh is captured at listener attachment rather than read from a View on the metrics thread.

The callback's third parameter is named and exported as `droppedReports`: Android defines it as FrameMetrics reports dropped because the consumer could not keep up, not as displayed frames dropped. It is diagnostics-quality evidence only.

Dart drains the same bounded ring/summary no more often than the existing ~2s cadence probe and emits `platformWindowFrameMetricsOutlier` / `platformWindowFrameMetricsSummary`. Debug Trace must not schedule a UI notification frame for either event.

## Interpretation / stop conditions
- High `UNKNOWN_DELAY_DURATION`, or intended-vsync materially preceding actual-vsync on API 26+, supports Android Window/UI-thread availability or scheduling delay rather than Flutter Build/Layout/Paint work.
- Low unknown delay but high sync/command-issue/swap or total duration supports the Window/render/compositor handoff path.
- Healthy Window metrics while Choreographer still skips intervals moves the owner outside measured Window rendering phases; inspect looper/vsync delivery and Perfetto rather than changing Reader policy.
- Healthy Choreographer + Window metrics + ScrollUpdate cadence, with visible jitter still present, moves the next boundary to actual SurfaceFlinger/display presentation cadence. Do not respond by restoring touch resampling, 180ms debounce, static Flutter projection, prefetch-threshold tuning or frame-rate policy.

## dev.320 high-performance amendment
The 23:59 high-performance trace shows the Window listener is not a continuous proxy for Flutter SurfaceView content presentation: only 62 Window metrics are reported while Choreographer continues at ~120Hz through the scrolling interval. Eight exported Window outliers collapse to four unique vsync timestamps and all precede the first active scroll observation. Therefore the prior `UNKNOWN_DELAY` candidate is limited to startup Window/ViewRoot frames and MUST NOT be promoted to the scrolling root cause. dev.320 retains FrameMetrics as supplemental diagnostics, deduplicates identical vsync callbacks, and adds first/last-vsync coverage metadata; the next causal boundary is per-Flutter-frame scene-motion continuity.
