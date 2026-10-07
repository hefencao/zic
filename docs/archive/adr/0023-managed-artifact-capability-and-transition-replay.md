# ADR 0023: Managed chapter artifact capability and deterministic transition replay

## Status

Accepted in `0.31.0-dev.40`.

## Context

The durable App root opens a chapter download service that also owns promoted Reader page artifacts and their busy-safe
maintenance adapter. The variable was typed as the narrower `ChapterDownloadService`, so passing it to
`ResourceCacheCoordinator` did not compile even though both concrete production/fallback implementations happened to
implement maintenance. Making every possible chapter command adapter implement artifact storage would conflate two
contracts and make test or remote command proxies own cache behavior they do not provide.

The midpoint host regression also used a fixed pixel drag as a proxy for two semantic states: target host creation and
current-page transition. Viewport dimensions, device pixel ratio and gesture slop can change that mapping. A null target
creation counter therefore did not prove a product remount.

Finally, dev.39 introduced enough trace events to attribute a blank transition, but no deterministic replay model yet
converted the event chain into phase durations and explicit missing evidence.

## Decision

1. Add `ManagedChapterDownloadService`, combining `ChapterDownloadService`, `ArtifactCacheStore` and
   `ArtifactCacheMaintenance`. Memory and persistent artifact owners implement this capability.
2. Keep `ChapterDownloadService` narrow. App durable root composition uses `ManagedChapterDownloadService`; UI/session
   APIs may continue to accept the command/read contract when they do not require artifact maintenance.
3. Midpoint regression gestures advance until observed target-host creation, assert the original page is still current,
   then advance until the controller reports the actual page transition. Creation/disposal counts remain strict.
4. Construct exact page `DownloadId` and trace identity in `downloads`, beside the promoted artifact identity owner;
   App code must not rebuild the resource prefix.
5. Add `ReaderTransitionTraceAnalyzer` in `telemetry`. Replay is partitioned by session and transition revision, then
   identifies the work revision that actually produced the presented frame.
6. Replay reports artifact-cache/origin selection, host dispose/remount evidence, transition-to-first-frame time,
   decode/upload queue and work durations, presentation delay, dominant measured phase and missing events. A neighboring
   page already ready before the midpoint has zero transition wait while retaining its earlier work revision.
7. Replay is observational. It cannot submit demand, instantiate media, retain a Widget, choose a prefetch window,
   clear/trim cache, or change memory budgets.

## Consequences

- App composition is statically correct without casts and without forcing cache ownership onto all chapter adapters.
- The Reader regression fails on semantic host/current-state violations rather than viewport-specific pixel guesses.
- Rapid-swipe traces can distinguish gesture transitions from the work that produced a frame, and identify which measured phase dominated before any owner changes.
- Origin selection alone does not claim network duration; incomplete event chains remain explicitly incomplete.
- Retention and memory-pressure changes still belong to pipeline/session/media owners and require replay evidence.
