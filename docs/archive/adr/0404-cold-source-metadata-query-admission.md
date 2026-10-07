# ADR 0404: Cold source metadata query admission

Status: Accepted

## Context

The first metadata-tag navigation from cold Home creates `ComicSourcesPage`
with an already issued query command. Its initial state ignored requestedQuery;
only didUpdateWidget consumed a later queryRevision. The source page therefore
opened correctly but requested an empty-query Latest page. Warm source pages
were unaffected, which concealed the defect in the earlier integrated route test.

The ordinary Release trace confirms queryLength0/Latest after a real Chinese
tag tap. A first-mount regression requests route-tag but observes an empty query
before the repair.

## Decision

Seed the existing page query and text controller from the trimmed initial
requestedQuery before scheduling the original source load. Preserve the default
empty query and existing queryRevision handling for mounted pages. No route,
intent mirror, retry, transport or source authority is added; normal browse,
keyword locking and original pagination remain in their current owners.

## Validation

The first-mount regression fails before the repair and passes after it. Existing
title-result return, nested warm-tag routing and source browse regressions pass.
Fresh2321 Dart/Flutter tests,27 analyzers, Rust22 and six ordinary APKs pass;
native libraries and Dex match the accepted0403 baseline. A real cold Home tag
tap reaches the original single-source page and its first browse request carries
queryLength2/offset0, with no preceding empty-query browse. This proves query
admission, not a successful upstream search response. Evidence is tracked in
`docs/archive/audits/source-metadata-cold-query-2026-10-07.json`.
