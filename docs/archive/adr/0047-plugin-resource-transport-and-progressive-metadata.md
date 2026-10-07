# ADR 0047: Plugin-owned resource transport and progressive chapter metadata

Status: Accepted in `0.31.0-dev.63`.

## Context

External sources do not always expose stable HTTP URLs. Mihon pages and covers may require extension headers or an opaque resource token; Venera pages may require source JavaScript callbacks. Passing those locators to `IoTransport` fails because the ordinary transport neither understands the scheme nor owns the plugin runtime.

The previous imported-chapter validation also treated a delivery URI as a unique page identity. Some valid sources repeat the same image URL at different positions, so this rejected a legitimate chapter even though each page had a distinct stable ID.

Mihon chapter catalogs frequently omit page counts because resolving them requires a page-list request. Rendering every zero as a permanent “pending” value hid useful metadata, while eagerly resolving every chapter serially would block details and create an accidental second page-loading policy.

Venera's native bridge delegated redirects to `HttpURLConnection`. Intermediate cookies were therefore not committed by the host, and a cookie-dependent redirect sequence could hit the platform's automatic follow-up limit. Synchronous download snapshot replay could also update Reader's transfer notifier during Widget build.

## Decision

1. `ImportedPageRecord.pageId` is the per-chapter stable identity and must be unique. A resource URI is a mutable delivery locator and may repeat.
2. `downloads` owns page transport selection. `PersistentChapterDownloadService` accepts an optional `ChapterResourceLoader`; source-owned opaque locators use `LoaderTransport`, while ordinary locators keep the existing I/O transport. App composition only resolves the active `BrowsableComicSource` and injects `loadResource`.
3. Source-provided media extensions may populate `contentKindHint` and `animatedHint`, but sniffing actual bytes and codec validation remain authoritative. Unknown opaque tokens receive no guessed media type.
4. Mihon zero page counts are progressively preflighted from remote details with at most two workers. Calls pass through `CachedBrowsableComicSource`, and only the current manifest/library projection is replaced. No page-byte cache or download policy is added to Presentation.
5. A Mihon synthetic gallery chapter is accepted only after a real non-empty page list succeeds. Catalog failures may be bypassed for this exact gallery case, but are attached to the page failure when both paths fail.
6. Mihon covers are normalized to source-owned resources containing the absolute URL and source request headers.
7. Venera HTTP redirects are followed by the host for at most eight hops. Cookies are persisted after each response, relative locations are resolved, POST-like requests follow standard 301/302/303 conversion, and Cookie/Authorization are removed across origins. URLConnection and the DNS-fallback OkHttp client both disable internal redirects.
8. Reader transfer progress is coalesced within a frame and published after build when a synchronous session snapshot arrives during a non-idle scheduler phase.

## Consequences

- Reader, persistent downloads and offline artifacts use one lifecycle for normal and plugin-owned pages.
- UI code remains unable to open plugin URIs, choose transports or retain page bytes.
- Duplicate delivery URLs no longer collapse or reject stable pages.
- Mihon details become useful incrementally without blocking the route or issuing unbounded requests.
- Venera redirect behavior is deterministic and diagnosable instead of depending on hidden platform follow-ups.
- Media hints improve early WebP routing but cannot override malformed or contradictory bytes.
