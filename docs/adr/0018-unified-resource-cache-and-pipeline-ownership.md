# ADR 0018: Unified resource cache and pipeline ownership

- Status: accepted
- Version: `0.31.0-dev.36`
- Supersedes: cache and Reader-retention decisions in ADR 0017

## Context

Covers, comic details, chapter metadata and search results need bounded reuse, request coalescing and explicit refresh.
Downloaded chapter pages also need capacity management, including partially downloaded chapters. At the same time,
Reader page demand, encoded artifacts, decoded frames and textures already have authoritative pipeline/session owners.
Putting separate cover/page caches in `apps/app/lib` duplicated policy and allowed Widget lifecycle to compete with
`DemandPlan`.

## Decision

Create `resource_cache` as a dependency-light package. One `ResourceCacheCoordinator` exposes the response cache
plane and coordinates the existing artifact-maintenance plane. Reusable response caching covers four resource kinds:
image bytes, comic details, chapter metadata and search results. One manager applies global and per-kind budgets, TTL,
in-flight coalescing, LRU, source-composite namespaces and stale-response suppression after invalidation.

Expose caching to sources through `CachedBrowsableComicSource` in catalog. Explicit source refresh invalidates search or
comic namespaces. Cache-key construction and exact comic invalidation stay in catalog adapters rather than Presentation.
The response image kind is limited to explicit cover/artwork resources. Keep `loadResource` raw: Reader/download page
bytes bypass response caching and enter the existing pipeline/session/artifact path. Local folder imports persist the
first page identity as explicit cover metadata; a missing remote cover does not silently turn a chapter page into a
response-cache entry.

Represent incomplete offline chapters as separate chapter metadata and independent page artifacts. The memory fallback
uses the same page-granular contract: a completed page is retained before progress is published, cancellation/failure
preserves that subset, and retry only requests missing pages. Keep artifact inspection/trim/clear behind
`ArtifactCacheMaintenance` and `CacheOps`; coordinate statistics and maintenance through `ResourceCacheCoordinator`,
not a new physical owner. Cache trim thresholds and response targets live in its `ResourceCacheMaintenancePolicy`, never
in Download Manager. An injected coordinator remains authoritative and is not rewrapped by App composition.

Move chapter download services and durable whole-comic scheduling into `downloads`. Put runtime network/power and JSON
persistence adapters in `downloads_bridge`. App code composes these interfaces and renders state only.

Remove direct Reader current/adjacent warmup, the private page-byte LRU and implicit page retention. Page-role Widget
identity may reset zoom; pipeline demand and session identities determine physical reuse.

## Consequences

- Cache budgets and invalidation are shared across covers, details, chapter metadata and search results.
- A late request cannot repopulate a cache after refresh or clear.
- Partial chapter data is visible and evictable per page rather than hidden behind a whole-chapter flag.
- Reader has one resource-policy authority again.
- App Presentation files remain large in places, but non-presentation cache/download algorithms are no longer defined
  there; later decomposition can proceed along state-owner boundaries.
- Decode latency and transition flashing still require telemetry-guided work in pipeline/session/media; this ADR does not
  claim they are solved by response caching.
