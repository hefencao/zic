# ADR 0007: Remote comic source browser and first-party source contract

- Status: Accepted
- Version: `0.21.0-dev.24`

## Context

The application needs a third primary destination for remote comic discovery without allowing
source implementations to bypass catalog identity, the durable library, or Reader artifact
ownership. Reusing Android-only extension APKs directly would also couple the Flutter application
to a separate Kotlin plugin runtime before zic has a stable source ABI.

## Decision

`catalog` owns a small first-party remote source contract:

- `BrowsableComicSource` extends the existing `ComicSource` chapter contract;
- `ComicSourceDescriptor`, `SourceComicSummary` and `SourceBrowsePage` describe discovery data;
- `loadResource` is used for source-browser covers and metadata resources;
- opening or saving a chapter converts its `ChapterManifest` to `ImportedChapterRecord`, then uses
  the existing library and Reader paths.

The first implementation is `MangaDexSource`. It uses the public MangaDex API for browse, search,
comic metadata and chapter feeds, and resolves page URLs through MangaDex@Home. The built-in source
requests English translations and safe/suggestive ratings only. It does not implement login,
cookies, challenge solving, site scraping, or anti-bot bypass.

The Android application adds a third `漫画源` destination. Its top app bar exposes source
management; enabled sources are switched through a bottom source strip. Enablement and ordering are
stored in SQLite schema version 3 through `ComicSourcePreference`.

Remote delivery URLs are not stable catalog identities. `ImportedPageRecord.pageId` persists the
source-provided page identity separately from its current URI. Before a remote chapter is opened,
the source resolves a fresh chapter manifest; progress reconciliation follows the stable page ID.

## Consequences

- Remote pages continue through `ReaderRuntimeScreen`, `DownloadSession` and promoted artifacts.
- Source browsing can be tested with injected source implementations without network access.
- New native or external plugin systems can later adapt to `BrowsableComicSource` instead of
  owning application navigation or Reader state.
- A source may fail because of network, upstream API or regional availability; the UI surfaces a
  retryable source error rather than silently falling back to direct site scraping.
- Mihon/Keiyoushi extension compatibility remains future work and requires an explicit isolated
  adapter/runtime, versioning and permission model.
