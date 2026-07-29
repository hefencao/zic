# ADR 0012: Download task projection and management

- Status: Accepted
- Version: `0.25.0-dev.29`
- Date: 2026-07-29

## Context

`0.23.0-dev.27` made a chapter download durable, but the application still exposed it as a
single blocking command. Home and Bookshelf could not observe authoritative progress, and users
could not cancel, retry or remove offline chapter artifacts without deleting library metadata.
Widget-owned counters would be incorrect after restart and would race the existing
`DownloadSession` state machine.

## Decision

`ChapterDownloadService` is the application boundary for chapter download tasks. It publishes
`ChapterDownloadSnapshot` values containing source-composite chapter identity, comic/chapter
labels, page progress, byte progress, terminal phase and copyable failure details.

The persistent implementation derives every snapshot from the existing
`DownloadRegistry -> DownloadSession -> Artifact` state. It does not create another downloader or
progress database. A terminal phase is retained while late session callbacks drain so completion,
failure or cancellation cannot be overwritten by an older receiving snapshot.

The application provides a Download Manager surface with per-chapter cancel, retry and offline
artifact deletion. Deletion removes only offline page artifacts; saved comic metadata, imported
chapter metadata, reading progress and read state remain owned by `ImportedLibraryStore`.

Home and Bookshelf aggregate chapter snapshots by exact `sourceId + comicId`. During an incomplete
download the shared cover card is dimmed and displays a bottom-up page/byte-derived waterline,
percent and completed/total pages. A fully downloaded comic restores the unobscured cover and uses
a compact offline badge instead of a permanent dark overlay.

The in-memory fallback implements the same lifecycle and must own complete page bytes before it may
publish completion.

## Consequences

- Reader, details, Download Manager and cover cards observe one authoritative artifact pipeline.
- Partial artifacts survive cancellation and remain resumable by the persistent service.
- Removing an offline chapter does not erase reading or library state.
- Download Manager can only manage chapters still represented by the durable library model. Orphan
  artifact discovery and cleanup remain a separate diagnostics task.
- Aggregate cover progress uses the saved source catalog as the total when available, so downloading
  one chapter does not falsely report the entire comic as complete.
