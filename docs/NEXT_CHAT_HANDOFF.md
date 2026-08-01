# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.79_stability-recovery.zip`

Do not merge dev.65–78 candidates, overlays or remembered source trees. Mihon and VibeVenera references remain read-only. The user-provided libwebp 1.6.0 archive is validation input, not a ZIC source overlay.

## Completed in dev.79

- Venera JavaScript source operations are single in-flight in `plugin_host`; Mihon retains configured runtime concurrency. The WebView raw `loadInfo` cache was removed, leaving comic-detail caching to `resource_cache/catalog`.
- Source-owned absolute artwork locators, including `mihon:resource:`, route through `ComicSourceResourceGateway`; `ResourceCacheManager` coalesces the entire encoded-image resolution.
- DownloadSession source listeners now project readiness, every length change, seal and failure, and immediately replay an already-ready snapshot to a late listener. Decode retries the same growing source demand and Upload receives terminal failures instead of indefinite loading.
- Unknown continuous-page extents are stable across currentIndex changes. Idle geometry replacement preserves a top-visible pixel anchor and active scrolling cancels pending restoration.
- Runtime/header-confirmed Animated WebP overrides source vertical hints in adaptive mode unless a per-comic direction override is explicit.
- Added ADR 0063, dev.79 audit/static gate and owner tests. +7/-3, +2/-1, current/transition and 5/3/2 remain unchanged.

## Device/toolchain validation still required

1. Run `flutter analyze`, all Dart/Flutter package tests (especially plugin_host, resource_cache, sessions, reader, reader_runtime and App), then Android debug/release or kernel snapshot.
2. Keep a Venera source active across repeated browse/details/chapter calls and app background/foreground; verify no `null.children` runtime degradation. If the source script still fails, capture source ID, operation arguments hash and sanitized stack because upstream DOM/source logic may also be invalid.
3. Cold-start and warm-start Home with HTTP, `mihon:resource:` and Venera cover locators. Confirm one stable request/cache identity and durable hits after restart.
4. Test large Animated WebP whose first 64 KiB is insufficient: it must start as later chunks arrive, finish on seal, scroll out/back without infinite loading, and show an error for authoritative source/decode failure.
5. In continuous mode scroll through unknown-to-measured page sizes; verify no pullback. With adaptive enabled, confirm a runtime-confirmed animation becomes LTR/RTL paged while explicit comic direction remains untouched.

## Rejected regressions

Do not restore the WebView raw `loadInfo` cache, Presentation-owned WebP cursor/decoder, App-private cover bytes cache, currentIndex-dependent unknown extent, timer polling, infinite source retries, or reduced preload/lane settings.
