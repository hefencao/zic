# ADR 0358: Immutable chapter manifest projection

Status: Accepted

## Context

Home canonical and version authority refreshes repeatedly convert unchanged
hydrated chapter records into manifests. Each conversion parses every page URI.
The current Release loading run records separate whole-library builds around
57–60ms and 71–73ms; rejecting opaque path/hash proof removes only one cost.

## Decision

An immutable `ImportedChapterRecord` lazily retains its own read-only manifest
projection. Every new record, including `copyWith` with a changed same-revision
provider locator, builds an independent projection. Records and manifests both
retain immutable page lists. Persistence continues to encode explicit record
fields, and mutable Reader progress stays outside this projection.

This introduces no cache map, service, worker, scheduler, retry, byte residency,
or new authority. Home still commits current chapter/version/media authority
synchronously; existing native source-write/decode workers remain unchanged.

This refines ADR 0357's manifest-cache exclusion only for the immutable record's
own derived representation. Its no-op upsert and synchronous authority contracts
remain in force; no Home scope-level manifest cache is added.

## Validation and limits

The record/manifest immutability and same-revision locator regression passes,
as do the focused Home/Reader/version tests. Current complete gate and fresh
device validation are recorded in the loading/chapter/plugin regression audit.
Synthetic repeated-conversion timings do not establish overall device jank.
Ordinary Release device builds now record later canonical/version refreshes
around 2–8ms/0–2ms; the first startup projection still costs 53–70ms and is
tracked independently. Acceptance covers the immutable projection contract.
