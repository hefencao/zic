# ADR 0010: two detail pages with shared components and centralized routing

- Status: Accepted
- Version: `0.23.0-dev.27`
- Supersedes: ADR 0009

## Context

A remote source owns a complete, mutable upstream catalog. The durable library owns saved comic
metadata, user preferences, imported chapter manifests, reading progress, read state and offline
bytes. A single stateful details screen forced those two lifecycles into one projection and enlarged
the failure and regression surface.

Whole-comic actions are also more common than persisting one arbitrary chapter. A user must be able
to collect or add a comic to the shelf before any chapter is downloaded. Conversely, the primary
chapter-level durable action is downloading that chapter.

## Decision

Keep two state owners:

- `RemoteComicDetailsScreen` owns source loading, transient source failures and the complete upstream
  chapter catalog.
- `LocalComicDetailsScreen` owns the durable comic snapshot, saved chapter/read state and offline
  download status.

Both pages compose the same header, preference controls, category controls, chapter rows, error
presentation and pull-to-refresh scaffold. `resolveComicDetailsRoute` is the only entry decision: a
source card routes to local details only when the exact `sourceId + comicId` already has durable comic
metadata or chapters; otherwise it routes to remote details.

`SavedComicRecord` persists comic metadata and a lightweight chapter-catalog snapshot independently
of imported chapters. Whole-comic liked/shelf/collected/category actions retain or remove that record.
Opening a chapter persists the source manifest needed by Reader. The chapter trailing action performs
a durable offline download; it does not change whole-comic preference semantics.

Cross-source migration is copy-based and conservative. The user selects a target source, searches
that source by the current comic title and confirms one candidate; a manual native-ID fallback remains
available for sources with incomplete search. It copies whole-comic preferences to the chosen target.
Only chapters with matching normalized title and sequence are eligible for automatic
metadata/progress/read-state migration. Target-source manifests are fetched anew.
Source URLs, offline bytes and the original source are never copied or deleted. Native ID collisions
that could overwrite the current legacy single-field preference/chapter keys abort or skip migration.

## Consequences

- Remote and durable state no longer compete inside one Widget lifecycle.
- The visual and interaction language remains shared without forcing one data owner.
- A zero-chapter comic can exist in the shelf or collection.
- Chapter downloads have an explicit persistent owner and can be reused by Reader after restart.
- Equivalent works across sources are not automatically merged by title.
- A future schema migration must make preference, progress and read-state keys fully source-composite;
  until then collision guards are part of the migration contract.
