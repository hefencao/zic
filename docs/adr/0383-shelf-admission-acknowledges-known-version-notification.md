# ADR 0383: Shelf admission acknowledges known version notification

Status: Provisional

## Context

First shelf admission clears the chapter update signal. An already-discovered
successor can independently keep the old comic in Home's update list because
its version family still has different shelf and latest-known heads. Preference
updatedAt also changes for likes and categories and cannot identify which
version notification the user acknowledged.

## Decision

ComicPreference persists an optional acknowledgedVersionComicId through its
existing JSON contract. First shelf admission captures the currently known
version identity. The Home notification projection omits that same successor;
a later successor remains eligible. Ordinary preference edits preserve the
acknowledgement rather than consuming newly discovered notifications.

The existing alias preference merge preserves the newest non-null stored
acknowledgement. Same-source preference migration preserves it; cross-source
migration does not carry a foreign source's version identity. Existing target
preferences retain their acknowledgement.

Relation history, shelf/latest/download heads, version reuse, sourceUpdateAt,
progress and Reader/transport authority remain independent. Missing legacy JSON
fields mean no acknowledgement; no database schema or new owner is introduced.

## Validation

The actual Home preference callback fails before the change for a known
pre-admission successor. Four update cases, real progress/metadata callbacks,
first admission and later chapter/successor checks pass with the candidate.
Model JSON, SQLite reopen/backup, Home snapshot and app backup checks pass.
The independent widget owner uses the existing injected primary-frame seam
inside one runAsync operation; production frame waiting is unchanged.
Required gate2217/27 suites/Rust22 and three-ABI Profile/ordinary Release
builds pass; the ordinary Release is installed and its general Reader/download
regressions pass. First-admission/later-notification device acceptance remains
pending, so this ADR remains Provisional.

The subsequent controlled-source device entrypoint passes 20 checks in a
minified Release: production Home/details callbacks, SQLite reopen and backup
preserve acknowledgement, relation history and progress while later chapter
and version signals remain visible. Before/after user backups have identical
semantic sections. It uses a separate temporary database and proves no real
origin discovery. The restored ordinary Release independently matches all four
Home update cases, refreshes the real 27-chapter catalog without changing any
saved record, and runs Reader155→144→155 with only progress.updatedAt changing.
Its 1014-event export has 19 artifact-cache reads, no downloads or task failures.
Gate2219/27 suites/Rust22 passes; live-source first-admission/later-version and
final-display acceptance remain separate and this ADR stays Provisional.

Evidence: `docs/audits/home-update-shelf-admission-acceptance-2026-10-03.json`.
