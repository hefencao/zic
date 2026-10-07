# ADR 0381: Reader adjacent query projects current comic family

Status: Accepted

## Context

Reader route construction queries previous/next chapter metadata through
_readerChapterSequence. Its whole-library projection aggregated every comic,
materialized source catalogs, sorted global results and canonicalized source
locators before selecting the current comic. Matched Profile CPU samples place
this work inside specific Reader build intervals. These samples do not explain
every GC, entry long frame or ordinary Release build outlier.

The query needs the current canonical comic family. Home lists still need the
complete library and keep their existing projection. Current alias selection
uses the selected representative's raw identity; changing that selection would
be an independent behavior change and is outside this decision.

## Decision

The App composition's pure homeReaderComicForChapter first selects records of
the current source, resolves each distinct raw comic ID at most once within
this invocation, and submits only the matching canonical family to the
existing aggregateImportedLibrary/collapseCanonicalLibraryComics projection.
It preserves selected raw identity, metadata, catalog, entry/progress objects
and the existing logical chapter order, boundary checks and entry anchors.
Every call reads fresh source canonical authority and current durable inputs.

No persistent cache, owner, worker, queue, Reader state or source model is
introduced. Home's global library projection is unchanged. Network, media,
preload, cancellation, 7/3 and 2/1 windows and budgets retain their owners.

## Validation

The original whole-library implementation fails the public helper test by
querying unrelated-source authority. The candidate passes this failing-first
case. Additional coverage compares alias/catalog/metadata and entry identity
with the existing projection, checks invocation-local canonical reads and
observes catalog/source-authority changes on a later call.

Gate2211/27 suites/Rust22 and three-ABI Profile/ordinary Release builds pass.
22 matched Reader frames contain zero legacy global-library getter samples;
the scoped family projection remains observable. Ordinary8430-event acceptance
passes five stationary cached sliders, four head/tail crossings, native browse
page/source return and five Mihon main-list version/ABI rows with no taskFailed.
Five screenshots/XML show no image error/loading placeholder; the ordinary
22.905ms build remains without matching CPU attribution. Temporary sampler
flags/forward are restored and current ordinary Release remains on Home.
Independent long-frame/GC/input and final-display performance remains open.

Evidence: `docs/audits/reader-adjacent-catalog-query-2026-10-03.json`.
