# ADR 0310: Version-family canonical media union

## Status

Accepted — 2026-09-12

## Context

This ADR refines ADR 0205. ADR 0205 remains authoritative for the exact `DownloadId` consumer/provider identity and the prohibition on late-merging two live sessions; this ADR replaces its temporary assumption that cross-version physical sharing is only a runtime-local alias to an already-existing exact carrier.


Zic currently has three different identities that were partially collapsed during earlier version-reuse work:

- source/version provenance (`ComicVersionRelation` predecessor/successor edges);
- exact provider/byte identity (`DownloadId`, including raw `comicId`, source revision and URI);
- physical media ownership (`DownloadSession`/partial/artifact carrier).

Treating a concrete newer version as the physical authority creates a false lifecycle problem: when B or C appears after A, the implementation starts asking whether A must be rebased to C and whether A's partial must be rebound. That is not an inherent property of version reuse. It is a consequence of using a version-specific `DownloadId` as the physical canonical identity.

The intended canonical model is a stable union of the version family's known media. A version may add pages that exist only in that version; old-only pages may remain present; an unverified or genuinely different body must not conflict with an already-known body merely because it occupies a similar ordinal. A newer version changes its own projection into the union, not the identity of media already present in the union.

The existing `canonicalComicId` cannot by itself serve as this version-family identity. For the current Venera/E-Hentai path it canonicalizes each gallery URL, so `/g/<old>/...` and `/g/<new>/...` remain different values even though `#gnd` confirms a version relation.

## Decision

### 1. Canonical is an abstract family union, never a concrete version head

A source-confirmed version family owns a stable opaque `VersionFamilyId`. No raw `comicId`, `latestKnownHead`, `shelfHead` or `downloadHead` is the canonical media identity.

`latestKnownHead`, shelf state and manual-download state remain useful presentation/user-state projections, but they never rename physical media.

Adding a new family member is monotonic metadata growth:

- existing canonical media identities stay unchanged;
- verified equivalent pages bind to existing canonical media;
- pages unique to the new version add new canonical media;
- old-version-only media remains valid for versions that reference it;
- unverified or conflicting bodies remain separate instead of forcing either side to replace the other.

Normal version discovery therefore has no media `rebase` operation.

### 2. Family membership is durable and additive

`ComicVersionRelationStore` remains provenance. A separate family-membership owner assigns an opaque `VersionFamilyId` when the first confirmed relation/component becomes relevant to canonical media and then only adds confirmed raw version members to it.

If a newly discovered relation has one known member, the other member joins that same family. Source-history rows for unopened versions do not create page/media state by themselves.

If a future relation unexpectedly connects two independently materialized family IDs, that is not a normal successor update. It must fail closed for cross-family physical reuse and enter an explicit reconciliation/repair path; runtime must not silently alias family IDs or walk an alias chain.

### 3. Canonical page media uses stable compact segments, not version page numbers

A canonical chapter family is represented by stable opaque media segments. A physical media coordinate is conceptually:

`VersionFamilyId + CanonicalChapterId + SegmentId + offsetWithinSegment`.

`SegmentId` is allocated once and never renumbered. Segment ordering is not physical identity; each concrete version owns its own ordered projection through the canonical segments.

This avoids an N-page canonical table. An 8k-page version that is one continuous run can be represented by one segment plus one interval projection. If a later version inserts three unique images in the middle, those three images create one additional segment; the original segment and all existing physical keys remain unchanged.

A version-specific projection maps compact exact page-index intervals to canonical segment intervals. Existing `VerifiedComicVersionPageInterval` evidence is an input to constructing/updating that projection, not itself a runtime predecessor→successor traversal contract.

### 4. Gaps and replacements never force unrelated media to move

For an incoming version interval:

- a verified-equivalent run maps to the existing segment(s);
- an inserted/old-only run maps only for versions that contain it;
- a verified mismatch does not rewrite the surrounding segment identities; that exact run receives separate canonical media while the remaining verified ranges continue to use the existing segment;
- an unknown span has no cross-version canonical binding until evidence exists.

A later mismatch may split a *version projection interval*, but it does not split/rename the canonical segment identity itself. Existing `(segmentId, offset)` physical identities remain stable.

### 5. Exact provider identity and canonical physical identity are different types

`DownloadId` remains the exact logical/provider identity. It continues to own:

- raw source/comic/chapter/page locator;
- source revision;
- request URI;
- provider bucket and retry/source capability;
- ETag/Last-Modified validator scope;
- exact manual/download/export semantics.

Canonical physical transfer ownership must use a version-independent physical key, not a synthetic `DownloadId` borrowed from A/B/C. An exact page with a verified canonical projection resolves directly to its canonical media key before physical session creation. An exact page with no canonical projection remains exact-only.

`DownloadTransferOwner` already retains `claim.exactId`; provider transport and validators must continue to use that exact claim even when several exact claims share one canonical physical transfer.

### 6. Mutable partial belongs to canonical physical media from creation

Once an exact page has a canonical media projection, the mutable `DownloadSession`/writer/partial is created under that canonical physical key from the start. Subsequent versions that map to the same media attach claims to the same physical owner.

There is no normal-path partial `rebind`. If two independent live/exact physical sessions already existed before equivalence became known, late evidence does not merge or rename them. They finish/retire independently; future acquisitions use canonical state. Any optional duplicate cleanup is a maintenance concern, not runtime ownership semantics.

### 7. READY immutable artifacts keep exact logical bindings separate

Immutable body objects may be shared by many exact logical bindings through the existing artifact-object/binding separation. Manual pin state, explicit download placement and export layout remain exact user/logical state.

Canonical physical ownership therefore does not mean "replace every old version with the newest version". It means "all versions resolve verified shared media into one stable family media space while retaining their own exact presentation/request semantics".

Download management must reflect that same split. The cache view is a physical projection, not one row per exact version: pages with a direct canonical coordinate are grouped by `VersionFamilyId + CanonicalChapterId` and counted once even when several exact versions have resident bindings. A persisted canonical projection is only stable coordinate memory; it does not by itself reactivate cross-version authority after proof revocation. Historical exact READY artifacts may be projected/backfilled under canonical only while the current active verified range (or a stronger stable media identity) authorizes that exact page. A canonical `physical_media_artifact` that was already committed remains a physical fact even if later proof is withdrawn, while new exact claims fall back to exact ownership. Unverified or inactive exact-only gaps remain exact cache rows.

When active canonical authority first appears, already-existing exact cache state is backfilled from residency only: the index is scanned once and uncached pages are never probed. READY candidates are grouped by canonical physical coordinate and bound without copying immutable bodies. Historical mutable exact partials may also converge when the current authority resolves that exact page: the longest existing prefix is committed to the canonical physical-partial path first, then the exact row is retired only if an expected-record guard proves it did not change during the commit. A crash may therefore leave a harmless duplicate, never destroy the only durable prefix. Busy rows, races, inactive/revoked proof and unmapped gaps remain exact. No Reader demand is required.

Manual download state remains a separate exact projection. Pinning a current version may add an exact logical binding to the same immutable artifact object, but it does not remove the underlying canonical cache row. A canonical cache-to-download action may target an authoritative shelf/latest exact version; if that target is not currently materialized, UI must not guess an older resident version merely because its bytes are present.

### 8. No runtime multi-hop or all-pairs candidate search

Runtime lookup is:

`exact version page -> direct canonical media key`.

It is never:

`A -> B -> C`, nor `A -> {B,C,D} -> rank existing carrier`.

Historical pairwise relations may be consumed by a control-plane builder while learning a family projection, but the published state is always direct exact-version→canonical-segment projection. Reader/download/cache hot paths do not BFS version history, compose predecessor offsets, enumerate all versions or materialize an all-pairs page matrix.

### 9. Complexity is structural-change bounded

Persistent/runtime canonical state scales with:

- confirmed materialized family members;
- canonical chapter/segment runs;
- compact interval projection changes.

It does not scale with `versions × pages`, `versions²`, or the number of unopened source-history versions. A large unchanged overlap remains one/few intervals regardless of chapter page count.

## Consequences

- Pairwise `VersionPageAuthority.directCandidates()` remains only a compatibility/evidence surface for pre-canonical state; the production hot path resolves a verified exact page directly to its canonical `PhysicalMediaId` and must not regress to runtime carrier enumeration.
- Physical session/registry ownership is split from the consumer's exact `DownloadId`: the physical key may be canonical while the claim retains its exact provider/request identity. Pre-existing exact generations are allowed to retire without late merge/rebind.
- `ComicVersionPageMapping` remains useful provenance/evidence, but predecessor→successor offset composition must not define runtime canonical coordinates.
- `canonicalComicId` remains a source alias/artwork comparison identity unless a source explicitly supplies a stronger version-family identity; it is not automatically `VersionFamilyId`.
- `latestKnownHead`, `shelfHead` and `downloadHead` remain presentation/download-management projections only.
- Normal version discovery, cache reuse and partial continuation require neither canonical rebase nor partial rebind.

## Implementation evidence

The production path is now implemented through a stable `VersionFamilyId` + compact canonical projection that resolves an exact page directly to `PhysicalMediaId.canonical`. `DownloadId` remains exact provider/logical identity and still owns validators, explicit manual pin/download/export state and source request semantics. Runtime physical ownership, durable canonical READY, and durable canonical partials are separate indexed facts; no concrete old/new version is renamed into the canonical owner.

The implementation also closes the durable-management boundary: promoted artifacts bind canonical physical ownership, canonical READY can restore before exact/equivalent carrier lookup, explicit manual/whole-comic commands can zero-copy materialize their exact target from the physical body, and canonical partials persist under the physical key with provider validators deliberately excluded from cross-version state. Force reload invalidates stale canonical routing while preserving an already-pinned/manual exact binding.

Download management projects canonical physical READY/partials once per family coordinate while keeping exact/manual completion separate. Global artifact-cache `inspect/trim/clear` now includes physical-only READY and physical partial bytes; shared exact+physical immutable bodies are byte-counted once, physical-only objects participate in capacity eviction, and a surviving pinned/busy exact READY binding preserves its canonical physical owner. Per-canonical-row bulk deletion remains deliberately deferred because it requires an ownership-aware delete plan rather than iterating visible version rows.

The 2026-09-10 Android checkpoint validates the primary ownership path on existing user data. A 371-page version and a separately addressed 464-page successor retained distinct raw `comicId` values while the persistent canonical projection survived cold restart. Pages unique to the successor remained exact-only. For the verified overlap, successor indexes 93/94/95 and predecessor indexes 0/1/2 resolved to three pairwise byte-identical `physicalMediaKey` values; every compared acquisition reported `canonicalDirect=true` and `legacyAlias=false`. This demonstrates direct exact-version→canonical-media ownership rather than choosing one version's exact carrier at runtime.

The selected-version preparation also remains target-scoped: the target details route retains its `originComicId + preparation` context until the route exits, and the target Reader performs only that direct relation's bounded catch-up before physical demand. Generic Reader entry remains non-blocking with respect to historical version proof.

## Validation requirements

Focused validation must demonstrate at least:

1. A large initial version creates O(segment-count) canonical state rather than O(page-count) rows.
2. Adding B with an unchanged overlap plus a small insertion leaves all A canonical physical keys unchanged and adds only the insertion segment/projection.
3. Adding C after A/B does not rewrite A/B segment IDs or partial ownership.
4. An old-only or new-only image can coexist in the family union and is visible only through versions whose projection contains it.
5. A verified mismatch affects only the relevant version projection/run; unrelated canonical media identities remain unchanged.
6. An unverified gap stays exact-only and cannot reuse a canonical body.
7. Two exact provider URIs can demand one canonical physical transfer while validators remain provider-URI scoped.
8. A canonical mutable partial created by A is directly reusable by later B when B maps to that same media, without copying, rebinding or selecting A as a special carrier.
9. Runtime resolution performs no version-graph traversal and no all-pairs candidate ranking.
10. Dozens of unopened historical versions add provenance only and do not increase Reader page-resolution work.
