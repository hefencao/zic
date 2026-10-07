# dev.312 Android ARR ballistic audit

## Device evidence entering the change

The 09:28 dev.311 Trace contains 72 scroll cadence outliers, 57 of them `dragDriven=false` ballistic; ballistic median is 28.194ms and max is 46.744ms. It contains 87 platform cadence outliers, of which 70 have `systemFrameGapMicros >= 20000`. Reader frame intervals >=20ms continue to show low Flutter build/raster cost, and exact interval overlap does not identify decode, Flutter-image upload, or reconcile as a unified cause.

All 48 `framePipelineTiming` samples are `renderer=flutterImage`, so the dev.311 presentation switch was real and is now falsified. The same run raises median Flutter-image `outputPrepareMicros` to about 31ms; production default is therefore rolled back to the already-known dev.310 Android texture path while the independent ARR test is introduced. Since dev.310 itself reproduced the bug, that rollback cannot explain a future improvement.

## dev.312 boundary

1. Fix the Android import to `android.view.Choreographer`; `android.os.Choreographer` is invalid.
2. Keep the cadence probe observation-only and add per-outlier main-thread CPU-gap plus display refresh-rate metadata; API >=36 also records `Display.hasArrSupport()`.
3. Add a distinct Activity-aware frame-rate policy channel. On API >=35, vertical Reader lifetime disables `Window.isFrameRatePowerSavingsBalanced` and restores the exact prior value on every exit/detach path.
4. Emit `platformFrameRatePolicy` start/stop evidence so a device run cannot accidentally be interpreted when the policy did not apply.
5. Keep touch sampling, ScrollPhysics, geometry, 3/7 encoded, 2/1 decode, NetLane, current±2 presentation continuity and independent Animated WebP ownership frozen.

## Next decision

A positive device run requires confirmed `applied=true/currentBalanced=false` plus material collapse of post-lift ballistic and Choreographer gaps. Otherwise ARR is rejected and the next artifact is an Android System Trace/Perfetto capture, not another Reader-level timing tweak.
