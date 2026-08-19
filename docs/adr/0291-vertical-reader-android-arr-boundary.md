# ADR 0291: Vertical Reader Android adaptive-refresh boundary

## Status

Accepted in dev.312 as a Reader-scoped, device-falsifiable platform scheduling intervention.

## Trigger

The 09:28 dev.311 run falsifies the renderer-topology experiment: `renderer=flutterImage` is active, but post-finger-lift ballistic cadence remains at the same ~28ms median scale and Android Choreographer still reports repeated >=20ms system-frame gaps. Long Flutter frame intervals mostly have build/raster work far below one frame budget, and exact interval overlap does not support decode/upload/reconcile as a unified cause.

The symptom boundary is unusually specific: dragging is substantially smoother, while the severe cadence failure appears after finger lift during ballistic/fling. Android 15 / API 35 introduced Window adaptive refresh-rate power-savings balancing and explicit View fling-content velocity hints. This creates a platform mechanism whose activation boundary directly matches the observed transition without requiring a ScrollPosition mutation.

## Decision

Keep the existing Choreographer probe observation-only. Add a separate `FlutterReaderPlatformFrameRatePolicy` owned by `reader_runtime`. While a vertical Reader is mounted on Android API >=35, the native Activity-aware adapter snapshots `Window.isFrameRatePowerSavingsBalanced`, sets it to `false`, and restores the exact prior value on Reader exit, Activity detach/recreation, or plugin teardown. Other app routes are untouched. API <35 is a no-op.

The policy MUST NOT write ScrollPosition, change ScrollPhysics, synthesize frames, alter Reader geometry, or change Pipeline resource policy. `platformFrameRatePolicy` Trace events record whether the native policy was actually applied.

Enhance the existing cadence observer with main-thread `Debug.threadCpuTimeNanos()` delta and current display refresh-rate metadata on outliers. On API >=36 also record `Display.hasArrSupport()` so an unsupported device cannot be misclassified as a negative ARR experiment. A large wall/frame gap with small thread-CPU delta further separates platform pacing/waiting from Java main-thread work.

## Falsification

On the next same-device reproduction, require `platformFrameRatePolicy.phase=start`, `applied=true`, `currentBalanced=false` before interpreting cadence. Compare post-finger-lift ballistic `scrollCadenceOutlier`, `readerFrameTiming.frameIntervalMicros`, and `platformFrameCadenceOutlier` against dev.311.

- If ballistic/system-frame gaps collapse materially, Android ARR/frame-rate policy is causal. Keep the Reader-scoped fix, then consider replacing the coarse Window disable with a velocity-aware hint only if power behavior warrants it.
- If gaps remain at the same scale while the policy is confirmed applied, close ARR as root cause and capture Android System Trace/Perfetto around Choreographer/SurfaceFlinger/display scheduling. Do not return to touch resampling, geometry, renderer switching, or control-plane micro-optimization.
