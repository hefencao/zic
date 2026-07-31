# ADR 0043: Preserve Mihon chapter identity and normalize Venera settings

- Status: Accepted
- Version: `0.31.0-dev.59`

## Context

A compatibility fallback for gallery-style Mihon sources created a synthetic
single chapter. Applying that behavior outside the empty-catalog case caused
real multi-chapter catalogs to lose the chapter object required by the
extension's page-list implementation. Venera sources already identify an
entry by its returned episode ID and reload that exact entry. Venera also
publishes declarative `settings`, but ZIC exposed settings only for Mihon.

## Decision

1. Treat a non-empty Mihon chapter list as authoritative and preserve every
   returned object. A synthetic `正文` is created only when the list is empty.
2. Execute `prepareNewChapter` in both supported Mihon ABI adapters before the
   catalog crosses the runtime protocol.
3. Retain live chapter objects by opaque chapter ID for the session. If the
   object is absent after restart, refresh the catalog and require one stable
   identity match; never substitute the manga object or first chapter.
4. Map Venera `switch`, text/input, select, multi-select and callback settings
   to the existing `ConfigurableComicSource` protocol. Keep values typed in
   runtime-private persistent storage and require the approved storage
   capability.
5. Presentation renders only normalized settings. It neither reads plugin
   storage nor owns plugin restart/session lifecycle.

## Consequences

- Multi-chapter Mihon sources retain per-chapter URLs and extension state.
- Gallery sources with no explicit chapter catalog still open as one chapter.
- Venera settings share the Mihon settings screen without source-specific
  storage logic in the app layer.
- Missing or ambiguous refreshed chapter identities fail explicitly rather
  than opening the wrong chapter.
