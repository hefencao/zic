# ADR 0016: Source migration comparison boundary

- Status: accepted
- Version: `0.29.0-dev.34`

## Context

Cross-source migration already copied preferences conservatively and only transferred reading state for chapters
whose title and sequence matched. Confirmation, however, only displayed a compact count. Similar titles across
sources can refer to different editions, languages or works, and native IDs are intentionally source-local.

## Decision

Derive a read-only `ComicSourceMigrationComparison` from `ComicSourceMigrationPlan` before any durable write. It
reports source and target identities, title/author evidence, reading direction, exact and sequence-only chapter
matches, unmatched counts and bounded chapter samples. Present both works side by side with independently loaded
covers. Require the user to acknowledge the target identity and risks before enabling the copy action.

The comparison cannot access `ImportedLibraryStore`. After confirmation, the existing flow still reloads and
validates every exact target chapter before its first write. Sequence-only matches remain informational and never
receive copied reading state.

## Consequences

- A matching title is no longer the only visible migration evidence.
- Native source identity differences and incomplete chapter reconciliation are explicit.
- Cover rebuilds do not repeat network requests during acknowledgement changes.
- The conservative migration and offline artifact ownership rules remain unchanged.
