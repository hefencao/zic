# ADR 0060: Page-local Reader loading ownership

Status: Accepted in `0.31.0-dev.76`.

Supersedes: ADR 0053 decision 7.

## Context

ADR 0053 moved loading feedback to one Reader viewport overlay and asked page renderers to suppress their internal indicators. In the current Pipeline-owned Reader, that created a second presentation authority: `ReaderView` tracked a page-ready set from first-frame callbacks while `LocalImagePlayer` and `NativeWebpPlayer` still owned their actual loading/ready/invalid phases. In stitched vertical mode the viewport overlay stayed fixed at screen center while the page-media indicator moved with the image, so both could be visible.

The attached immediate-exit trace contains no exception or lifecycle failure. It shows the stable seven-page demand window, page artifacts promoted before route exit, and all seven demands detached when Reader closed. Therefore the visual duplication must be fixed in Presentation without shrinking Pipeline windows or making Reader cancel resource sessions.

## Decision

1. The concrete page-media widget is the only visible owner of loading/ready/invalid feedback. Its indicator is centered inside that page's presentation area.
2. `ReaderView` owns geometry, interaction and observations only. It does not maintain a page-ready set and does not paint a viewport-level loading overlay.
3. `_ReaderPageHost` may deduplicate first-frame callbacks and record telemetry. First-frame telemetry is observational and cannot drive a second visible loading state.
4. Page media does not expose a `showLoadingIndicator` suppression compatibility flag to Reader.
5. Unknown vertical geometry keeps a page placeholder at least as tall as the active viewport so the page-local indicator remains visible. Measured geometry continues to use `height / width`, without overlap, negative translation or cropping.
6. Reader exit detaches through the existing `pipeline_runtime` host/binding lifecycle. Reader does not close DownloadSession, transport, artifact, decode or upload owners.
7. Pipeline windows and lanes remain +7/-3 encoded, +2/-1 decode, current/transition upload and 5/3/2 concurrency.

## Consequences

- Stitched vertical Reader displays one loading indicator that follows the loading page rather than a fixed screen overlay.
- Reader no longer duplicates media readiness state or rebuilds a full-screen Stack on first-frame events.
- Local-media tests own page loading behavior; Reader tests reject restoration of a global spinner and continue to test first-frame telemetry separately.
- Existing route, cover, settings and command-button progress indicators remain local to their own owners and are not affected.
- Current-page WebP first-frame performance remains a device-validation topic; it is not hidden by reducing prefetch or progressive decode behavior.
