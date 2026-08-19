# dev.306 Vertical continuous control-plane hot-path audit

## Baseline and trigger

- Unique code baseline: the formal dev.305 tree built from the user's newly uploaded `zic.tar.gz` baseline.
- Device trace: `zic-debug-trace-2026-08-19T03-32-25.jsonl`.
- User result: strong vertical continuous jitter remains after dev.305.

## Evidence

- dev.305 common 1-added/10-changed/1-removed reconcile median is about 4.73ms versus about 8.39ms in the preceding baseline: the scheduling-migration fast path works, but the symptom remains.
- Layout snapshots continue to show zero extent delta, stable layout residual and identity scale/shear. A large visual position jump is not supported by current geometry evidence.
- The exported trace represents about 1,197 `readerObservation` and about 1,021 `pageTransition` source events, but only 132 `policyDecision` events. Most scroll samples therefore do not create a new scheduling plan.
- Several active-scroll frame intervals exceed 30ms while the interval contains no policy/reconcile/texture/page-host event. This requires auditing work that happened for every observation but was not timed as reconciliation.

## Source audit

Before dev.306, `PipelineReaderSession.accept()` executed on every drained Reader observation even when `PipelineController` returned without a new revision. The no-revision path still performed output prewarm checks, startup pressure checks, `ReaderBinding.accept`, `_syncPageStreams`, transfer-progress selection, artifact scheduler refresh, `_syncPageOutputs` and playback ticker work.

`ReaderBinding.accept()` also rebuilt an entire chapter pageId→index map and upload-id projection for every observation before calling `PlaybackGate.apply()`. For vertical continuous scrolling, numeric coverage changes frequently while playback semantics remain the same.

The Reader trace path additionally constructed `readerObservation` and `pageTransition` TraceEvent payload maps near frame cadence even though DebugTrace later coalesced them. dev.294's layout probe also remained at an active 10Hz despite repeated stable-layout device evidence.

## Closure

- PipelineReaderSession now filters vertical control-no-op observations before `accept()`.
- ReaderBinding uses continuous vertical viewport semantics and skips redundant playback synchronization; page-index/upload projections are cached.
- PipelineReaderSession's post-binding stream/output/artifact control synchronization runs only after plan/current/DecodeTarget change.
- PipelineController commits window metadata without a scheduler revision when DemandDiff is empty.
- Reader/transition diagnostics are semantic-edge/250ms sampled and active layout probing is reduced to 500ms plus forced boundaries.

## Non-goals

No change to geometry, ScrollPhysics, texture compositor behavior, sourceCanvas, encoded/decode windows, NetLane capacity, scheduler priority or local-image byte ownership. This round tests whether continuous viewport facts were incorrectly driving control/diagnostic work at frame cadence; it does not claim GC/engine/platform scheduling is already excluded.
