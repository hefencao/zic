# ADR 0056: Pipeline runtime ownership and shared request plans

## Status

Accepted in `0.31.0-dev.72`.

## Context

The Reader composition still created and selected parts of the download/progress runtime even though the architecture assigns download, decode, upload, retry and artifact state to Pipeline. Home, source browsing and details also loaded plugin artwork through separate complete-byte calls. Venera therefore had multiple callers capable of resolving the same image configuration, and HTTP covers incorrectly reused the chapter-page resolver.

Reducing preload or scheduler concurrency would hide symptoms while degrading the VibeVenera-derived pipeline.

## Decision

1. Introduce `pipeline_runtime` as the composition owner for one Reader resource session.
2. `PipelineReaderSessionHost` creates/disposes the session. `ReaderRuntimeScreen` only submits `ReaderObs` and consumes `PipelinePageStream`, presentation bytes and read-only progress.
3. Pipeline derives the selected transfer identity from `ReaderObs.currentIndex`; Reader has no separate progress-selection command.
4. Local media widgets observe the read-only page stream and never receive `DownloadSession`.
5. Home, source browsing, details and migration artwork use `ComicSourceResourceGateway`, the shared source transport and `ResourceCacheManager`.
6. Venera HTTP artwork resolves through `onThumbnailLoad` when present. Durable chapter locators resolve through `onImageLoad`.
7. Request plans are coalesced and stored in bounded caches; completed image bodies remain owned by response/artifact caches, not the plan cache.
8. Preserve the +7/-3 encoded download window, +2/-1 decode-warm window and 5/3/2 lanes.

## Consequences

- Reader no longer imports or owns downloads, sessions, storage, transport or media pipeline implementations.
- One observation stream controls both demand planning and current-page progress projection.
- Repeated cover/page presentation can reuse request configuration and response cache without plugin complete-byte RPC.
- Authentication/settings changes require explicit source replacement/invalidation; plan caches are also invalidated on stream failure and retry.
- Actual Android Tx/Rx still requires device measurement. This ADR removes deterministic duplicate paths but does not claim network traffic has been empirically normalized in the SDK-limited environment.
