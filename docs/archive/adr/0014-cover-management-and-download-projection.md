# ADR 0014: Cover-owned management and download projection

- Status: Accepted
- Version: `0.27.0-dev.31`

## Context

Moving all bookshelf actions into a separate single-selection panel duplicated migration controls, made
frequent actions spatially remote from the selected comic, and competed with custom-order gestures. Download
projection also treated a chapter task as if it represented the whole comic and relied on route-local booleans,
so progress could remain stale or disappear after navigation.

## Decision

Single-item management belongs to the cover: isolated delete at the upper-right and category migration in a
lower-right popup. Long press exclusively starts source-composite multi-selection. The separate management bar
is batch-only. Custom reordering uses an explicit drag handle.

Details and cover projections consume authoritative `ChapterDownloadSnapshot` state. A chapter task displays
its own title and page denominator. Whole-comic download is an orchestration operation over per-chapter tasks;
it does not create a second artifact or transport owner. Active work alone receives a waterline. Complete work
uses a compact offline badge, and Download Manager omits its progress bar.

Cover cards contain no metadata rows: title is overlaid lower-left and reading progress belongs to details. Route
entry is coalesced by exact source-composite comic identity.

## Consequences

- Frequent single-item actions stay attached to their comic while destructive delete remains visually isolated.
- Multi-select and custom sorting have distinct gestures.
- Route recreation cannot erase an active download indicator.
- Whole-comic cancellation stops orchestration without weakening individual chapter task ownership.
- A future durable queue can replace the in-memory orchestration set without changing download artifacts.
