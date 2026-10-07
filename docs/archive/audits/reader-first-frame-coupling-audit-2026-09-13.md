# Reader first-frame coupling audit — 2026-09-13

## Scope

This audit reviews first-frame/startup optimizations that remain in production after the durable READY / canonical-owner work. The question is not whether an optimization mentions `current` or first-frame latency, but whether a presentation timing fact has become an unrelated transport, cache, durability, or lifecycle authority.

## Confirmed coupling removed

### Presentation readiness → NetLane local bucket

ADR 0108 introduced `_startupCurrentDownload`: while the current local page had no presented output, `PipelineReaderSession` changed the source bucket limit from the stable profile value 2 to 1, then restored it when the first output was presented.

That was a useful device experiment at the time, but it makes a presentation result rewrite transport capacity. The later architecture already has composition-owned local-read scheduling, deferred durable ingress, ranked physical preparation, and bounded source quanta. The stable `ReaderPipelineProfile` is now again the only owner of the local/remote source bucket limits; first-output state no longer changes NetLane capacity.

### Presentation readiness → composition-wide artifact pressure

The old startup pressure hold was armed synchronously by `PipelineReaderSession.accept()` and released from upload/decode presentation state. It therefore throttled unrelated local artifact work and storage writes even when the current page was remote and had not requested an artifact read. The later `reserveFirstForegroundQuantum` variant could block all background scheduler work until any foreground quantum happened to run.

Production Reader control no longer pre-arms `ArtifactCacheReadScheduler`. Foreground pressure is now created by actual foreground read requests/leases (or by an explicit operation-level pressure holder outside presentation policy), so local I/O priority remains owned by the local-read scheduler instead of by first-frame presentation. The global first-foreground reservation mechanism has been removed.

### Process media prewarm → Reader route readiness

The App started native decode-worker / texture prewarm while preparing a Reader route, but then awaited that speculative future before returning the prepared chapter. A slow texture bridge attach therefore turned an acceleration path into a route readiness dependency.

The prewarm now runs fire-and-observe. Chapter preparation never waits for it. The real decode and texture capabilities remain authoritative: native decode joins its own worker-start single-flight when needed, and platform texture creation joins/retries its own attachment path. A speculative prewarm failure is logged but cannot fail or delay chapter preparation.

## First-frame optimizations retained because their ownership is local

- Exact `DecodeTarget` output prewarm remains. It allocates only presentation resources, is bounded to current/transition/immediate-next roles, yields platform creation to an already scheduled Flutter frame for non-current roles, and does not create Download/Decode/Upload demand.
- Paged active-target first-frame UploadDemand remains interaction-gated. Idle neighbors are decode-only; dragging/scrolling/settling may add the explicit priority-820 upload only for the actual adjacent `targetCoverage` page. This includes a temporarily `previous`-classified reverse target before the stable 3/7 direction flips, without changing direction state or widening the role/decode/download windows. This is ordinary Reader observation → Pipeline policy, not a first-frame completion signal controlling another owner.
- Current decode/upload reserved handoff slots remain stable role policy. They are not armed or released by first-frame completion.
- Exact durable restore proof remains operation-scoped to `(DownloadSession, exact DownloadId, SourceEpoch, final length)` and only avoids a duplicate backend preflight. It does not grant cross-version or cache authority.
- `Ingress.append` first-chunk no-copy and Direct durable staging are storage/media implementation optimizations; neither changes policy or ownership.
- `WebpDecodePrefixHints` remains a bounded exact-DownloadId decoder retry hint. It is learned only from explicit `needMoreData`, is not durable/cache authority, and successful opportunistic source length cannot strengthen it.
- `DownloadSession.firstFrameRequiredPrefixBytes` remains transport-flow evidence only. Reader late-join replay does not consume it as a replay watermark.

## Regression boundary

The stable contracts are now:

1. Before first presentation, local source `downloadStarted.bucketLimit` is still `ReaderPipelineProfile.stable.localSourceConcurrency` (2).
2. Accepting a current Reader observation does not itself make `ArtifactCacheReadScheduler.foregroundPressure` true.
3. App Reader chapter preparation contains no `await mediaPrewarm`; process prewarm is observed asynchronously.
4. No global `reserveFirstForegroundQuantum` mechanism exists in the local-read scheduler.
5. Existing exact-output prewarm and interaction-gated paged active-target tests remain intact; idle previous/next2 and vertical hidden animated upload remain excluded.

Device validation should compare first-frame/source timing against the last release baseline after these ownership changes. In particular, source wait must not return to the earlier multi-hundred-millisecond durable replay path; if local contention regresses, fix it inside the local-read owner using actual queued work rather than reintroducing presentation-driven gates.

## Device validation

The clean audit tree was built from `78266bfe` plus only this audit's changes, rebuilt its own Android native artifacts, and installed with `adb install -r` on the existing device/data set. Five independent force-stop → cold launch → cached Ani Collections Reader opens were exported and analyzed.

For the current page, `mountToFirstFrameMicros` was 156163–176415 µs (median 168922). Frame-zero `sourceWaitMicros` was 24049–43383 µs (median 28049), native decode-worker readiness was 5–16 µs (median 6), `nativeDecodeMicros` was 41045–61518 µs (median 50246), and frame-zero end-to-end time was 61744–115694 µs (median 80297). All five runs had zero `taskFailed`, and logcat contained no ZIC FATAL/ANR.

The current canonical READY page remained local: current `physical-local-prepare` was 5394–19416 µs (median 15894), canonical READY bind 1017–8652 µs (median 1839), and the initial 256 KiB resident hydration was 9304–28389 µs (median 22571). This is the intended durable-completeness / Reader-ingress split; the old multi-hundred-millisecond whole-body replay did not return.

The release also confirms the important trade-off of this audit: adjacent READY preparation can overlap the current page again instead of waiting for a presentation-created global reservation. Current preparation remained bounded and ranked, while the first-frame distribution stayed inside the recent device range. If future traces show real local-read contention, it should be fixed from queued-operation priority inside `ArtifactCacheReadScheduler` / physical preparation, not by making presentation readiness a transport or storage authority again.
