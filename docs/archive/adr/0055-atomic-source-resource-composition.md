# ADR 0055: Atomic source-resource composition

Status: Accepted in `0.31.0-dev.71`.

## Context

The dev.70 streaming path needs both a complete-byte fallback for explicit plugin transforms and a streaming `ByteResponse` transport for ordinary images. App composition injected them with two unrelated capability setters through a variable statically typed as `ChapterDownloadService`. Dart did not promote that variable to either unrelated interface, causing compilation failure. Even with explicit casts, two mutations could expose a half-bound pair, while `_DemoHomeState` directly owned the transport pool and external download services could retain callbacks after Home disposal.

## Decision

1. Add immutable `ChapterResourceAccess` and aggregate `ConfigurableChapterResourceAccess`.
2. Persistent chapter downloads replace one `_resourceAccess` value and prefer its streaming transport.
3. Add `ComicSourceResourceGateway` as the App owner of source lookup, legacy locator rejection, transport-pool lifecycle, Reader response loaders and download binding.
4. The gateway unbinds live services before closing transports.
5. Keep the two legacy capability interfaces only as a compatibility fallback, with explicit casts.
6. Keep Home-specific chapter/download compatibility actions in a private State extension; pure locator/manifest logic remains top-level.

## Consequences

- Production downloads cannot observe mismatched loader and transport generations.
- UI composition no longer owns source transport internals.
- Externally supplied services do not retain stale gateway callbacks after Home closes.
- Older third-party/test download services continue to work without weakening the production ownership path.
