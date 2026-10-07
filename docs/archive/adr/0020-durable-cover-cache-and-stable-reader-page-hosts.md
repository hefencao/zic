# ADR 0020: Durable cover responses and stable Reader page hosts

## Status

Accepted for `0.31.0-dev.38`.

## Context

The unified response cache introduced one process-wide owner for cover/image
bytes, but its LRU entries existed only in memory. A fully downloaded cover was
therefore fetched again after process restart even though it was immutable
encoded response data suitable for bounded persistence.

Reader pages had a separate identity problem. `_ZoomableReaderPage` included
whether the page was current in its Widget key. `PageView` changes the current
index near the transition midpoint, so both the leaving and entering page could
be disposed and rebuilt at that moment. Media already presented by the page
host then returned to its loading/black state even though pipeline demand and
asset identity had not changed.

## Decision

1. `ResourceCacheManager` may use an injected `ResourceCacheByteStore` only for
   `ResourceCacheKind.imageBytes`.
2. `FileResourceCacheByteStore` persists complete encoded bytes plus the full
   `ResourceCacheKey`, expiry, content length and content hash under the app's
   durable storage root. It is bounded independently by entry and byte limits.
3. The standard image-response TTL is seven days. Explicit comic/source refresh
   and cache clear retain their namespace invalidation semantics across process
   restarts. Unified cache inspect/trim/clear includes this durable response tier
   separately from process-memory responses and page artifacts.
4. A cover key includes the available source revision. The URI/path remains the
   response identity; the revision distinguishes changed content at that
   identity.
5. A successful image request waits for its durable write before completing.
   Cache shutdown rejects new work but drains requests already in flight and
   their persistence queue before closing the store.
6. Reader page and zoom hosts are keyed only by stable page asset identity.
   Becoming current or non-current is an ordinary Widget update. It may reset
   page-local zoom state, but it must not dispose and recreate the media child.
7. This decision does not add a Presentation prefetch window, keep-alive cache,
   decoded-frame cache or texture-retention policy. Those remain pipeline,
   session, media and renderer concerns.

## Consequences

- Reopening the app can restore recently used covers without invoking the
  source loader.
- A stale or corrupt durable record is a cache miss and is removed; it is never
  returned as a different resource.
- Crossing the `PageView` midpoint no longer restarts an already loaded page
  merely because its current-page role changed.
- Source refresh, revision changes, TTL expiry and capacity trimming may still
  cause a legitimate reload.
- Reader page artifacts remain outside the response cache and continue through
  `DownloadSession`, promoted artifact handoff and pipeline demand.
