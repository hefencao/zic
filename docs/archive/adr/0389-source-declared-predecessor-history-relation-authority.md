# ADR 0389: Persist source-declared predecessor history through existing authority

Status: Provisional

## Context

Source discovery exposes both predecessors and successors of the requested
comic. HomeVersionReuseLifecycle displays both but originally persists only
successors. Discovering several successors of an old version creates several
terminal nodes. Viewing the latest version cannot complete that history from
its declared predecessors, so the runtime projection can retain no unique
latest head. Offline detail views also lose those newly discovered predecessors.

A behavior regression seeds old→middle and old→latest. The source explicitly
declares middle as a predecessor of latest. The old code fails because durable
history still contains only old→latest. This is independent of whether a device
has already acknowledged a Reader notice; absent notice screenshots alone do
not establish this cause.

## Decision

Normalize both directions from the existing source capability in the same
HomeVersionReuseLifecycle discovery step. Submit predecessor→current and
current→successor through HomeLibrarySession and ComicVersionRelationStore.
Reject foreign-source, empty and self identities. Preserve existing discovery
timestamps and page-mapping proof through the existing relation merge.

Do not infer relations from source dates, titles or presentation generation.
Do not relax ambiguous head selection, create media equivalence or change any
chapter/page identity, locator, revision, trust rule or cache authority. Reader
continues to consume the read-only Home projection. Existing post-first-frame
NetLane discovery scheduling and physical cancellation remain unchanged.

## Validation

The corrected regression has a genuine missing-edge failure before production
changes. Nine lifecycle checks pass after repair, including offline predecessor
retention, head completion from explicit evidence, invalid identity exclusion,
original discovery timestamp and unchanged page-mapping proof. The initial
test fixture compilation failure is separately retained and excluded.

Required toolchains pass2235 Dart/Flutter checks across27 suites, three existing
skips and22 Rust checks with no analyzer errors/warnings. Three-ABI Profile and
ordinary Release packaging, JNI/FFI, Dex/native/manifest checks pass. The exact
ordinary Release verifies five stationary sliders, four chapter boundaries with
history overrides, readable downloads and system WNACG v1.6.0/ABI1.6 in the
correct device-extension section. All119 complete chapter records stay identical;
only four progress and two read-state timestamps change.

The one-click trace is a saturated10000-event ring. Its retained interval has178
artifact-cache reads, no download/failure and four slider target frames within
48.545–122.256ms of release. Early source and first-slider records are absent.
The current E-Hentai adapter projects only successors; this device input does
not exercise the repaired predecessor branch. Real source-declared predecessor
acceptance and Reader notice acknowledgement preconditions remain unverified,
so this ADR remains Provisional. No claim closes the original19/20 loading cause
or final display/GC acceptance. Evidence:
`docs/archive/audits/source-declared-predecessor-history-2026-10-04.json`.
