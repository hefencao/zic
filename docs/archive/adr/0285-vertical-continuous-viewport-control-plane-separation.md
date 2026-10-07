# ADR 0285: Vertical continuous viewport / control-plane separation

Status: Accepted

## Context

The dev.305 device trace (`zic-debug-trace-2026-08-19T03-32-25.jsonl`) keeps the vertical layout falsification intact: actual page extents/residuals/transforms remain stable while strong visible jitter persists. dev.305 also reduced the common 1-added/10-changed/1-removed download reconcile median from about 8.39ms to about 4.73ms, yet the user still observes strong jitter. Several active-scroll 30–45ms frame gaps contain no policy/reconcile/texture/page-host event, so further DownloadSession/reconcile micro-optimization cannot explain the whole symptom.

The same trace exposes an unmeasured hot path: about 1,197 Reader observations produced only 132 policy decisions. Before this ADR, every observation still entered ReaderBinding/PipelineReaderSession, rebuilt upload page-index maps, ran PlaybackGate, refreshed page streams/outputs/artifact scheduling and emitted Reader/transition diagnostics even when continuous coverage/velocity changed without any discrete scheduling meaning.

## Decision

1. Vertical continuous geometry remains Reader-owned. Pipeline control observations are discrete: unchanged current/stable page, target page, visible page membership and interaction control phase are a control no-op. `dragging`, `scrolling` and `settling` share one active control phase. DecodeTarget dirtiness still forces the next observation through. Non-vertical paging is not filtered by this rule.
2. ReaderBinding resolves active vertical presentation with continuous Viewport semantics. Playback synchronization runs only when the resolved ViewportState or Pipeline plan revision changes; explicit late-output `resyncPlayback()` remains forceful.
3. The chapter pageId→index map and upload-id projection are cached by stable chapter/plan revision instead of rebuilt for every observation.
4. PipelineReaderSession performs prewarm/startup/page-stream/output/artifact/playback control synchronization only when the authoritative plan revision changes or current/decode-target identity changes. Coverage-only motion cannot own these control-plane lifecycles.
5. PipelineController does not manufacture a scheduler revision for an empty semantic DemandDiff merely because Reader window metadata changed. It still updates its cached window/visible metadata.
6. Diagnostic traffic is not a per-frame owner: readerObservation/pageTransition are emitted on semantic edges or a 250ms heartbeat; the repeatedly-stable dev.294 layout probe keeps forced scroll start/end samples plus a 500ms active heartbeat.

## Invariants

- Reader still reports every visual scroll observation locally; this ADR filters only Pipeline/control and diagnostic hot paths.
- previous3/next7, decode previous1/next2, NetLane normal5 + current reserved1, priority values, static presentation continuity, sourceCanvas, vertical geometry, ScrollPhysics and texture/presentation policy are unchanged.
- A changed current/target/visible membership, scrub/jump/idle boundary, DecodeTarget, or real DemandPlan semantic diff still reaches reconciliation normally.

## Falsification

On the same strong-jitter local-image continuous test, the next device trace should show substantially fewer control-plane observations/policy work relative to visual scroll frames and lower diagnostic churn. If 30–50ms active frame gaps remain strong after this per-observation path is mechanically removed, freeze Dart control-plane optimization and move to VM/GC/Flutter-engine/platform frame scheduling rather than returning to geometry or resource-window tuning.
