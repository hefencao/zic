# ADR 0063: Venera runtime and Reader stream stability

## Status

Accepted. Supplements ADR 0061 and ADR 0062.

## Context

After the atomic Pipeline media migration, device reports showed several coupled regressions: Venera `loadComic/loadInfo` could fail after runtime reuse with `null.children`; source-owned custom artwork locators missed the gateway after durable cache eviction; a native cursor that returned `needMoreData` was not awakened by later chunks; source/decode failures could remain visible as infinite loading; continuous geometry changed when currentIndex changed; and source vertical hints could override runtime evidence that a page was animated.

The regressions had different owners and must not be hidden by shrinking the established download/decode/upload windows.

## Decision

1. `plugin_host` selects invocation concurrency by runtime format. Venera JavaScript source operations are single in-flight; Mihon uses the configured isolated-runtime capacity. Host image transport remains independently concurrent.
2. The Venera WebView bootstrap does not wrap `comic.loadInfo` in a TTL promise/object cache. Serializable comic details are cached only by `resource_cache/catalog`.
3. App composition sends every source-owned absolute artwork locator through `ComicSourceResourceGateway`. `ResourceCacheManager` coalesces the complete `EncodedResourceSource` resolution, including durable lookup, loader and post-persist file location.
4. DownloadSession source listeners represent the full source lifecycle: creation/readiness, growth, seal and failure. A listener attached to an already-ready source receives the current snapshot immediately. LiveCoordinator wakes the same Decode demand for each lifecycle change.
5. DecodeSession treats ingress/source/cursor failure as authoritative. UploadSession projects failure or retains the prior successful surface; a page does not remain in loading and no automatic unbounded retry is introduced.
6. Unknown continuous-page extent is stable and independent of currentIndex. Geometry replacement preserves the top-visible page pixel offset only while idle; active scrolling cancels pending restoration.
7. Runtime/header-confirmed animation is higher-priority adaptive evidence than a source vertical hint. Explicit per-comic direction remains user-owned and is never overridden. File suffix alone is not conclusive evidence.

## Consequences

- Venera source metadata calls may have less script-level parallelism, but ordinary image bytes retain existing host transport and 5/3/2 lane capacity.
- Cached comic details are serializable and invalidated by the shared cache owner; raw plugin objects cannot outlive their invocation.
- Incremental decode may be scheduled repeatedly as bytes grow, but the keyed DecodeLane coalesces pending follow-up work.
- Errors become visible instead of appearing as permanent loading. Upstream Venera source/DOM errors can still occur and require sanitized device trace rather than host-side infinite retry.
- Adaptive mode may switch from an initial source-hint layout after actual animation evidence arrives. This is preferable to treating every WebP suffix as animated.

## Rejected alternatives

- Reduce +7/-3, +2/-1, current/transition upload or 5/3/2 lanes.
- Serialize all plugin formats or route image bodies through full JSON/Base64 RPC.
- Retain a WebView raw `loadInfo` cache beside `resource_cache`.
- Poll source length with timers or create a Presentation-owned decoder.
- Keep every cursor/texture alive forever to avoid replay.
- Use currentIndex-dependent placeholder height, negative translation, overlap or forced jumps to mask geometry changes.
- Treat every `.webp` resource as animated or override an explicit per-comic direction.
