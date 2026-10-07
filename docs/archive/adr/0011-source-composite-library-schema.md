# ADR 0011 — Source-composite durable library identity

- Status: Accepted
- Version: `0.24.0-dev.28`
- Date: 2026-07-28

## Context

Remote sources own their native comic and chapter identifiers. Two independent sources may legally
reuse the same `comicId` or `chapterId`. The application UI and `SavedComicRecord` already used
`sourceId + nativeId`, but schema version 4 still keyed imported chapters, progress, comic preferences
and read state by the native ID alone. Cross-source migration therefore needed conflict guards and
could not retain both records even though the product model treated them as distinct works.

## Decision

SQLite schema version 5 uses these keys:

- `imported_chapter`: `(source_id, chapter_id)`
- `reading_progress`: `(source_id, chapter_id)`
- `comic_preference`: `(source_id, comic_id)`
- `chapter_read_state`: `(source_id, chapter_id)`

`ImportedLibraryStore` requires the source identity for every point lookup/removal and for comic/read
queries. `ReadingProgress`, `ComicPreference` and `ChapterReadState` persist `sourceId` in JSON and
expose stable composite identities. App maps and Widget keys use the same identities.

Schemas 1–4 are upgraded transactionally. Chapter-owned progress and read state inherit source from
their legacy imported chapter. A legacy remote comic preference with several possible owners is
assigned deterministically using the newest saved-comic timestamp, then newest imported timestamp,
then source ID. Every ambiguous or orphaned resolution is stored in `library_migration_issue` and can
be queried through `listMigrationIssues()`. The migration runs `PRAGMA foreign_key_check` before
committing the new schema version; any invalid ownership graph rolls the transaction back.

Compatibility decoders accept an explicit source fallback for old JSON, but all new writes include the
source. Source-specific URLs and offline bytes remain outside identity migration.

## Consequences

- Different sources can retain identical native comic/chapter IDs without overwriting each other.
- Cross-source copy migration no longer needs to reject a target solely because its native ID exists
  under another source.
- Callers must always carry source identity; omitting it is a compile-time API error.
- Ambiguous legacy preference ownership is visible and auditable rather than silently discarded.
- Download management and migration comparison can now build on stable durable identities.
