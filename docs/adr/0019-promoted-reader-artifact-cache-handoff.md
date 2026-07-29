# ADR 0019: Promoted Reader artifact cache handoff

- Status: accepted
- Version: `0.31.0-dev.37`
- Extends: ADR 0018

## Context

Reader page downloads currently terminate in a process-local `EphemeralCacheWorkspace`. This keeps Widget lifetime from
owning physical resources, but disposal recursively removes every promoted page artifact. Reopening the same chapter
therefore repeats source transport work even though the prior session completed and sealed the exact page bytes.

The correction must not restore a Reader-private byte LRU, direct current/adjacent warmup, or a second demand owner.
Only the authoritative `DownloadSession` knows when an artifact is complete and safe to reuse.

## Decision

Define `ArtifactCacheStore` in `downloads`, beside the page-artifact implementation and `DownloadId` ownership. A store
may read an exact already-promoted page and may accept bytes only after the source session reaches
`DownloadState.promoted`.

Add two package-owned adapters:

1. `ArtifactCacheTransport` is a read-through transport. It checks one exact URI-to-`DownloadId` mapping in the durable
   artifact tier and otherwise delegates to the transport selected by `LiveCoordinator`. Ambiguous duplicate URI
   mappings bypass the cache. Range reuse requires a matching content-derived validator.
2. `PromotedArtifactCacheHandoff` observes sessions created by the Reader registry. It never creates demand or starts a
   download. After promotion it reads the final artifact, submits it to `ArtifactCacheStore`, and drains pending commits
   before the ephemeral workspace is deleted.

`PersistentChapterDownloadService` and its memory fallback implement the store through their existing page-granular
artifact ownership. Durable writes use `DownloadJob -> DownloadSession -> seal -> promote`; no App file copy or direct
index mutation is introduced. `ResourceCacheCoordinator` remains dependency-light and continues to coordinate only
response-cache policy plus artifact inspect/trim/clear.

## Consequences

- Reopening a Reader can populate its new session artifact from the durable page cache without another source/network
  download.
- A page is never submitted while partial, receiving or merely sealed; promotion remains the commit boundary.
- Reader Presentation only injects the store and composes the adapters. Cache write orchestration lives in `downloads`.
- Partial chapters remain a set of independent page artifacts. Reading some pages may make those exact pages available
  offline without claiming that an all-or-nothing chapter object exists.
- Encoded-memory, decoded-frame and texture retention are unchanged and remain future pipeline/session/media work.
