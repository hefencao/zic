# ADR 0359: Source model chapter catalog position

Status: Accepted

## Context

Mihon chapter IDs contain the full source-owned model plus host `comicId` and
newest-first `sequence`. A catalog refresh can change those host fields while
the source model remains the same. Exact-only Reader lookup then appends the
old current chapter to the new catalog and orders it with a stale ordinal.
Chapter URL alone is insufficient: sources may use name, number, memo or other
model fields in `getPageList(SChapter)`.

## Decision

Plugin-host compares the complete decoded source model, removing only `kind`,
`comicId` and `sequence`, the same host fields excluded by runtime `createModel`.
Nested map key order is normalized; all source-owned values remain inputs.
Home uses this read-only comparison only within one source/comic catalog.
Exact ID wins; a non-exact match is accepted only when unique. The authoritative
catalog supplies order, so an old current carrier does not add a duplicate node.

Runtime IDs, DownloadIds, saved metadata and source objects remain unchanged.
This comparison neither proves byte equality nor authorizes cache/page reuse;
adjacent materialization continues to use the catalog's actual chapter ID.
No alias store, metadata authority, listener, retry or transport gate is added.

## Validation and limits

Focused contracts cover changed ordinal/parent locator, preserved adjacent IDs,
source memo differences, ambiguous models, exact-ID precedence and malformed IDs.
Current complete gate and device evidence remain in the regression audit.
This does not claim that every historical same-title record is the same model,
or resolve the separate candidate of route availability after metadata refresh.
The required gate and current ordinary Release eight successful crossings
support the tested catalog boundary. Independent per-source acceptance remains
in the source/governance Plan; this decision does not alias same-title rows.
