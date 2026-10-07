# ADR 0386: Confirmed version selection consumes source refresh and honest dates

Status: Accepted

## Context

The generic migration entry freezes the initial cached version list, whereas the
detail shortcut consumes its source-owned background refresh. It also displays
opaque comic IDs. Stored relation discovery timestamps are projected as version
update dates, so older galleries appear updated today even after source refresh
has finished. The ordinary device reproduces both problems; a failing-first
owner test proves discovery time is incorrectly published as source date.

## Decision

The existing migration presentation module provides a pure version selection
dialog. Home passes the initial read-only list, its already-admitted owner refresh
Future and the existing source WebUri capability. FutureBuilder publishes the
refreshed list in the open dialog; failure preserves the initial list and closing
does not cancel owner work. View and migration return the exact selected version
object. Titles and ordinary Web addresses replace opaque display IDs. Actions
render below the full-width metadata so they cannot squeeze identifying text
into a narrow trailing-action remainder.

Stored relation discovery time remains proof metadata. Its date projection is
unknown until an actual source version date is available; successor and
predecessor fallbacks follow the same rule. No new schema, lookup, retry, source
owner, relation/family identity, cache trust or Reader policy is introduced.

## Validation

The owner regression covers both stored relation directions. Presentation tests
cover an open-dialog refresh and exact selection, failed refresh with cached
migration, and completion after the dialog closes. Required2224/27 suites/Rust22
and three-ABI Profile/Release/JNI/FFI checks pass. The ordinary Release verifies
readable actual source dates/URLs, the551-page target view off shelf, return to
the371-page original and unified comparison acknowledgement/close. Exported
page identities/URIs/revisions/progress and other sections are unchanged; one
target import timestamp refreshed during existing version preparation, recorded
as a separate hydration observation. This is not original Reader or final display
acceptance. Evidence:
`docs/audits/confirmed-version-picker-refresh-provenance-2026-10-03.json`.
