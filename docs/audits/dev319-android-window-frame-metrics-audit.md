# dev.319 Android Window FrameMetrics audit

## Device evidence entering dev.319
Input: `zic-debug-trace-2026-08-19T16-22-39.jsonl`.

The dev.318 composition experiment is valid but negative. There are 11 `mediaClassified` events and all 11 are authoritative one-frame static output (`animated=false`, `frameCount=1`, `complete=true`). `staticFlutterPresentation` occurs 12 times and there are zero `taskFailed` events. The Reader problem nevertheless remains. This closes the dev.318 static-WebP Flutter projection route and restores dev.317 native-texture presentation in dev.319; it does not reopen dev.315, which failed before a valid presentation A/B because it broke the exactly-one-current-per-lane invariant.

## Motion cadence is not independently halved by Reader
The 50 `scrollCadenceSummary` windows contain 2,006 non-zero motion intervals: 187 <10ms, 109 at 10–14ms, 1,521 at 14–18ms, 69 at 18–20ms, 54 at 20–25ms, 47 at 25–35ms and 19 >=35ms. The weighted mean is about 16.0ms.

The 19 `platformFrameCadenceSummary` windows contain 2,205 Android Choreographer intervals: 2 <10ms, 1 at 10–14ms, 2,096 at 14–18ms, 17 at 18–20ms, 27 at 20–25ms, 60 at 25–35ms and 2 >=35ms; mean 16.936ms. The display still reports 120Hz. The near one-to-one bin shape means Reader ScrollUpdate follows the cadence actually delivered to the app; there is no evidence here that a healthy 120Hz app frame stream is silently reduced to 60Hz by ScrollPosition.

This cadence fingerprint matches the prior 15:15 effective-~60Hz trace and is deliberately not treated as the high-performance device. The user explicitly identified 15:16 as high performance; that control had 4,761/4,772 Android intervals below 10ms and mean ~8.37ms.

## Cheap CPU / framework phases do not explain the long gaps
There are 97 `platformFrameCadenceOutlier` samples. Median `systemFrameGapMicros` is 26.294ms (max 66.441ms), median callback gap 26.508ms, median callback lag only 0.645ms and median main-thread CPU delta 6.897ms. Main-thread CPU/system-gap ratio is below 0.5 for 76/97 outliers and below 0.25 for 43/97. This is compatible with substantial waiting/pacing/blocking time rather than a continuously CPU-bound Android main thread.

Reader `readerFrameTiming` likewise contains long intervals whose Build/Layout/Paint/raster work remains small. Current platform outliers are not temporally explained by physical texture blits: no outlier lands within ±10ms of an actual blit and only one within ±30ms in this trace. Immediate reconcile is also not a universal correlate.

## dev.319 instrumentation boundary
Add Android Window `FrameMetrics` while the existing vertical Choreographer probe is active. Capture total duration plus unknown delay, input, animation, layout/measure, draw, sync, command issue and swap buffers; API 26+ also captures intended/actual vsync timestamps. Run the listener on `zic-reader-window-metrics`, keep a bounded 64-entry outlier ring plus fixed-bin summary, and drain through the existing low-frequency Dart probe.

`droppedReports` is the Android listener's report-loss count and MUST NOT be interpreted as dropped display frames. `UNKNOWN_DELAY_DURATION` is the key first discriminator because Android defines it as time waiting for the UI thread to become responsive and process the frame.

No Reader behavior is changed by dev.319 beyond retaining the already-beneficial dev.317 `Timer.run` seam. No 180ms delay, resampling, position smoothing, renderer switch, 7/3 or decode2/1 change, NetLane change, frame-rate vote or SurfaceProducer lifecycle experiment is introduced.
