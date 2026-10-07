# ADR 0351: Composition-bound static presentation capability

Status: Accepted

## Context

Pipeline accepts a raster-cache authority, but the mounted adapter and detached prewarmer were bound to a global adapter. The default App used the same cache in all three places, so its normal Profile evidence did not expose this coupling. An integration regression with a replacement authority fails before the fix: the injected owner has zero entries while prewarm writes to the global owner.

## Decision

App composition binds one existing raster owner into `PipelineStaticPresentation`. Its authority and prewarm method configure Pipeline; the same capability is passed explicitly to imported-page and mounted presentation. Consumers delegate exact resident lookup, resize and managed wrapping rather than selecting a global cache. Independent local raster rendering consumes the same pure resize policy without a cache dependency.

The capability holds only an immutable owner reference. Equal owner bindings preserve a mounted attempt; replacing the owner uses the existing load epoch/token retirement. Raster residency, claims, LRU, admission and maintenance remain in the original cache.

## Consequences

No second cache, scheduler, queue, timer or budget is added. App maintenance and memory pressure still target the original default process cache. The injection regression also covers exact detached-to-mounted reuse, same-owner rebuild and same-generation eviction/regrant. The injected-owner regression, full required-toolchain gate (2136 Dart/Flutter and 22 Rust tests), native Profile and minified Release builds pass. A complete 2077-event Profile trace and later stationary-slider, chapter-boundary and animated-reentry segments have no task failures. Later segments are ring-truncated; the wider product/source/performance checklist remains separate.

Evidence: [state-governance audit](../audits/state-governance-closure-2026-10-01.json).
