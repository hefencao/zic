# ADR 0017: Home composition and Reader cache boundaries

- Status: superseded by ADR 0018
- Version: `0.30.0-dev.35`

## Context

`apps/app/lib/demo_home.dart` had grown beyond 3300 lines and mixed durable library loading, download subscriptions,
cover loading, navigation, dialogs and Home/Bookshelf Widget composition.

## Decision at the time

The Home presentation split was accepted. The same iteration also added `CoverMemoryCache`, a per-Reader
`ReaderPageBytesCache`, direct current/adjacent page warmup, role-independent page identity and implicit adjacent
retention.

## Supersession reason

The file split reduced one monolith, but the cache decision violated the existing architecture: Presentation is
forbidden to pre-cache pages and `PipelineController` is the sole resource-policy entry. It also created separate
cover/chapter cache islands instead of one resource budget and preserved stale zoom state across page-role changes.

ADR 0018 retains the Home presentation split, removes the App-owned caches and moves cache/download policy to
workspace packages with explicit pipeline ownership.
