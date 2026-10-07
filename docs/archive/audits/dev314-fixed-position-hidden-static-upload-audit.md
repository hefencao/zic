# dev.314 fixed-position hidden-static upload audit

## Evidence source

- Device trace: `zic-debug-trace-2026-08-19T10-26-02.jsonl`, low-performance device only.
- Library comparison source: canonical `vibevenera-master.zip`, SHA-256 `fbd2bdfa8980f928c59d4af7a9cc162abbe9d283f9306c358b9a3cec4f5c38a7`.
- Relevant VibeVenera paths: `lib/pages/reader/continuous_images.dart`, `lib/pages/reader/image_support.dart`, `lib/foundation/image_provider/pipeline/pipeline_controller.dart`.

## Trace inventory

The trace contains 148 `scrollCadenceOutlier`, 145 `pipelineReconcileTiming`, 144 `policyDecision`, 118 `uploadStarted`, 58 `frameUploaded`, and 127 `platformFrameCadenceOutlier`. Outliers cluster by current page: index20=42, index12=19, index22=15, index23=13, index21=12, index11=11. This distribution and repeated same-position observation downgrade a global frame-rate cap from root cause to possible amplifier.

There are 19 ballistic outliers >=33ms. Eight exact gap windows contain `policyDecision` and `pipelineReconcileTiming`; seven contain `uploadStarted`, `pageCurrent`, `staticFrameKept`, and `lastFrameKept`. Some severe gaps contain none of these, so dev.314 explicitly does not claim to explain every platform cadence miss.

## Fixed-position physical example

At 40.658911s page11 is classified `animated=false`, `localPresentationReady=true`. The force-replan adds one hidden static upload. Dart-level `frameUploaded` identifies it as role `next2`, 712x2336. The corresponding Android platform upload reports `uploadMicros=16395`, `blitMicros=16163`, `surfaceReconfigureCount=1`, and completes at 40.677365s. A 32.845ms `scrollCadenceOutlier` ends at 40.679514s, so the expensive platform copy lies inside the affected scroll interval; a 33.846ms ballistic gap follows at 40.713364s. Across the trace, 19 platform uploads can be paired to a recent role-bearing upload by identity; 16 are `next2`.

## Source comparison

VibeVenera ordinary static pages use `ReaderImageProvider` inside `ComicImage`; known GIF/WebP streaming content uses the heavier streaming path. Its Pipeline's `onReaderPageChanged()` schedules a resettable `_dragCommitDelay = 180ms` during scrolling. ZIC instead funnels local static pages through the unified decode/upload/Android texture policy and, before dev.314, authoritative local-static classification could immediately enable hidden `next`/`next2` texture work.

## Intervention choice

Only the active hidden-static upload exception is changed. Decode prefetch remains warm, visible/current/transition upload is unchanged, idle pre-presentation remains, and no frame-rate vote or control debounce is added. This makes the next device run interpretable.
