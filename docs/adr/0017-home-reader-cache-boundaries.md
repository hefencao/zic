# ADR 0017: Home composition and Reader cache boundaries

- Status: accepted
- Version: `0.30.0-dev.35`

## Context

`apps/app/lib/demo_home.dart` had grown beyond 3300 lines and simultaneously owned durable library loading,
download subscriptions, cover-byte memoization, navigation, dialogs, bookshelf interaction and most Home/Bookshelf
Widget composition. That concentration made performance and lifecycle changes risky. Cover loads had no bounded
memory policy, Reader page bytes were re-read across adjacent page transitions, and a page key included current-page
state so changing pages could destroy and recreate otherwise identical media Widgets.

## Decision

Split the home shell into four responsibilities:

- `HomeLibrarySession` owns durable library projection, source preferences and download subscriptions.
- `demo_home_views.dart` owns Home/Bookshelf composition and management interaction.
- `home_widgets.dart` owns reusable cover, shelf and action components.
- `DemoHome` remains the application coordinator for navigation, dialogs and cross-feature use cases.

Use bounded encoded-byte caches instead of unbounded UI maps. `CoverMemoryCache` coalesces concurrent loads and
applies entry/byte LRU limits. `ReaderPageBytesCache` retains only the active page and bounded neighbours, shares
in-flight loads and cancels obsolete warmups. It does not own decoded frames or textures. Persistent offline cache
maintenance continues through the existing storage index and `CacheOps`; Download Manager only presents and submits
trim/clear commands.

Keep Reader page keys based solely on stable page identity. Enable implicit adjacent-page retention and preserve the
previous image while a replacement frame is installed. DecodeSession, native frames, textures and promoted artifacts
retain their existing owners.

## Consequences

- `demo_home.dart` is reduced to an orchestration-sized file and has an enforced line budget.
- Cover and Reader encoded-byte memory are bounded and observable instead of process-lifetime maps.
- Adjacent page navigation can reuse in-flight or cached bytes and no longer remounts a page merely because its
  current/near role changed.
- This stage reduces avoidable loading and flashing but does not claim to replace native decoded-frame/texture cache
  policy. Decode latency and frame deadlines remain measurable work for the media pipeline.
