# ADR 0052: Venera entry preflight and gapless continuous pages

Status: Accepted in `0.31.0-dev.68`.

## Context

Persisted Venera chapter records may contain generation-scoped
`venera-resource://token` values. Such values are not network locations and
cannot be reconstructed after the owning runtime is gone. A detail-screen hint
such as `refreshRemote: false` must not be allowed to bypass adapter
compatibility. Repeatedly submitting an unrecoverable locator to Reader demand
also amplifies failed runtime/network work.

Continuous vertical presentation has a separate ownership issue. Stitching is
not a zero-height decoration; it means there is no separator render object.
Unknown media geometry may temporarily need a placeholder, but that placeholder
must keep the active loading indicator in the viewport and must be replaced by
measured geometry without cropping.

## Decision

Every Reader and download entry checks chapter locator compatibility. A legacy
Venera locator forces `RefreshableChapterComicSource.refreshChapter` even when
the caller does not request ordinary content refresh. If refreshed metadata is
still legacy, the command fails before Reader/download composition.

The App source-resource composition and Venera runtime adapter independently
reject generation-scoped locators before invoking the plugin runtime. These are
safety backstops, not alternate migration owners. Durable
`venera-resource:<payload>` remains the only locator accepted for new Reader
work.

Deferred Venera resources use a conservative Reader demand profile: current and
one forward encoded page, with at most two download demands and no automatic
Reader network retry. In-flight work may still be shared by stable URI;
completed bytes remain owned by the existing session/artifact lifecycle.

Stitched vertical mode uses a builder list with adjacent page children and no
separator. Non-stitched mode alone creates the eight-logical-pixel separator.
The active page uses at least one viewport of placeholder extent until reliable
geometry exists, then reflows from source or measured dimensions. Stitched
static images, Flutter animated frames and native textures share one width-fit
presentation contract, preventing contain-style rounding margins from exposing
the Reader background. Parent extent remains source/measured geometry, so images
remain complete and uncropped.

## Consequences

- A stale stored chapter causes one metadata refresh instead of repeated page
  resource failures.
- A future UI path cannot accidentally send old Venera tokens to the runtime.
- Venera startup traffic is bounded more conservatively than ordinary HTTP/file
  chapters.
- Stitch mode cannot show a deliberate separator; any remaining seam must come
  from source pixels or incorrect measured geometry and can be diagnosed as
  such.
- Loading indicators for the active continuous page remain centered in the
  current viewport while dimensions are unknown.
