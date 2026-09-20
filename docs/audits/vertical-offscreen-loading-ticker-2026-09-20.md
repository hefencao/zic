# Vertical Reader offscreen loading ticker ownership audit (2026-09-20)

## User-visible symptom and first separation

The user reported that previously cached static vertical pages sometimes appeared to download again. The first layer was already separated and fixed in commit `19269961`: exported traces showed zero network download for the static vertical reproducer, but App-private Direct cached presentation opens were serialized behind the unrelated single-thread SAF path executor and took seconds. After that fix cached presentation leases fell to millisecond scale.

A second symptom remained: a static vertical Reader could stay hot after the current cached page was already visible. This audit intentionally treats that as a separate ownership problem instead of reopening download/cache policy.

## Evidence before the Reader fix

Fresh Profile `.log/zic-debug-trace-2026-09-20T00-53-06.jsonl` had zero `downloadStarted`, zero origin reads and stable Pipeline revision (max 14), but the static Reader produced 74 `readerFrameTiming` events and the Android main/platform thread sampled at 96–100% while idle. Local read, SAF path, raster and I/O workers were idle.

A temporary Debug-only `debugPrintScheduleFrameStacks` window captured the caller of the next Flutter frame. The recurring stack was `Ticker._tick -> Ticker.scheduleTick -> SchedulerBinding.scheduleFrame`, proving this was an animation ticker rather than Pipeline reconcile, a post-frame observation callback or network work. The diagnostic code was removed immediately after capture and never enters the product change.

Flutter Inspector on the same chapter then showed **60 `LocalImagePlayer`** nodes and **27 `CircularProgressIndicator`** nodes. Many loading indicators belonged to vertical pages outside the actual viewport (examples around current page ~68 included pages 61–64 and 78–80), along the path `_ReaderPageShell -> _ReaderPageHost -> LocalImagePlayer -> image-folder-preview-loading -> CircularProgressIndicator`. The indeterminate Material progress indicator owns a repeating `AnimationController`; cacheExtent/keepAlive therefore accidentally granted offscreen loading UI global frame-scheduling authority.

## Causal A/B

For diagnosis only, `_loadingIndicator()` was temporarily replaced by an equal-size static box while keeping all loading, cache and Pipeline state unchanged. On the same Profile device the Reader main thread, raster, I/O and local-read workers all fell to 0% after settling, and a three-second `gfxinfo framestats` window contained no app frames. That temporary UI change was reverted before the formal fix.

## Ownership fix

`ReaderView` already owns exact vertical geometry and computes `visibleCoverages`, `visibleMinIndex` and `visibleMaxIndex`. That existing fact is now also the sole UI ticker-admission boundary:

- `cacheExtent` and `current±7` keepAlive continue to decide whether a page subtree remains composed.
- Every composed vertical page is wrapped in a `TickerMode` driven by one shared visible-range notifier.
- A page outside `visibleMin..visibleMax` remains mounted and continues async source/cache/decode/presentation preparation, but all descendant Flutter tickers are muted.
- Re-entering the real viewport re-enables tickers without recreating the page subtree.
- Paged Reader is unchanged. Pipeline roles, encoded 7/3, decode 2/1, upload, NetLane and download/cache authority are unchanged.

This keeps visibility, composition residency and data preparation as separate concerns rather than making `current`, download state or a media widget infer viewport ownership.

## Validation

The dedicated Reader regression composes many vertical pages containing `CircularProgressIndicator` and verifies that the current tree contains both geometry-visible `TickerMode(enabled:true)` pages and cache/keepAlive `TickerMode(enabled:false)` pages. Reader package: **52/52**. ReaderRuntime: **25/25**. LocalMediaUI: **19/19**. App Reader cold-open + controls: **13/13**. Repository/Dart structure checks pass; focused analyzer has zero error/warning (only existing info lints).

Fresh Profile `.log/zic-debug-trace-2026-09-20T01-08-53.jsonl` on the same cached chapter shows **13** Reader frame-timing events versus **74** before the gate, with **0 `downloadStarted`**, **0 origin reads**, **19 artifact-cache reads**, and max Pipeline revision **14**. Main-thread idle sampling fell from 96–100% to about 7–11%; that residual is independently explained by the old dev.310 diagnostic Choreographer observer, which still emitted 19 `platformFrameCadenceSummary` windows of 115–120 callbacks each while Window FrameMetrics saw only sparse real frames. It is not a reason to reopen loading or cache ownership.
