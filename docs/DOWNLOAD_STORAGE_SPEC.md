# Download Storage and Transfer Contract

Status: Accepted normative contract for the storage/transfer boundary refactor.

This document is normative for the detailed download/storage behavior. `docs/SPEC.md` remains the project-wide specification and references this contract.

## 1. Logical identity and version cost

1. Reader page order MUST be the logical manifest order plus explicit Reader presentation settings. Reader MUST NOT inspect `DownloadPlacement.pageOrder` to decide logical order.
2. `DownloadPlacement.pageOrder` MUST describe only user-visible export layout.
3. Durable page placement MUST NOT be recomputed from a global `N-index` rule when a newer comic version changes page count.
4. Unopened or unmaterialized comic versions MUST NOT create per-page artifact/export bindings solely because a version relation was discovered.
5. Compact verified version-edge mappings MAY be composed lazily when a version is actually cached/downloaded. If compact proof is insufficient, automatic reuse MUST be skipped rather than expanded speculatively.
6. `ComicPageOrder.auto` MUST freeze before first structured page materialization. It MAY resolve to `chronological` only for a single-chapter comic with verified pure-front-prepend evidence; otherwise it MUST resolve to `origin`. Source/plugin names are not ordering evidence.
7. Materialized export pages MUST have sparse durable positive ordinals. An existing logical page's ordinal MUST NOT change during ordinary incremental/version reuse; a front-prepended page MAY only consume a new ordinal above the existing maximum. A change that would move an existing slot MUST fail as a policy conflict until an explicit export relayout is requested.
8. Verified version traversal MAY cross unmaterialized intermediate versions but MUST NOT create their per-page bindings. Only an already-materialized compatible anchor may contribute ordinals.

## 2. Metadata, artifacts and replicas

1. Long-term durable metadata authority MUST live in App-private storage and MUST NOT require moving the metadata database when the user's default export root changes.
2. Logical `DownloadId` binding and physical replica location MUST be separate authorities.
3. A logical artifact MAY have multiple replicas on private, direct POSIX or SAF roots.
4. Access failure on one locator MUST NOT invalidate another locator or the logical artifact.
5. A sealed artifact is immutable. Automatic-cache/manual-export distinction MUST be expressed by retention/export binding rather than requiring duplicate bytes.

## 3. Storage roots and Android access

1. SAF and direct filesystem paths MAY coexist as access locators for the same physical root only after an implementation-owned proof confirms they address the same directory.
2. Generic/unproven `content://` providers MUST remain SAF-only.
3. When direct and SAF locators are both healthy for one root, direct access SHOULD be the preferred data-plane path and SAF SHOULD remain an available fallback.
4. Switching preferred access for the same physical root MUST NOT copy bytes.
5. `accessDenied` MUST degrade the affected access locator, not delete replica/artifact metadata.

## 4. Cache and export placement

1. On a reliable direct POSIX root, automatic-cache objects MAY be colocated under a hidden ZIC-owned area so cache-to-export promotion on the same filesystem can use rename/reflink semantics.
2. Hard-link promotion MUST NOT be the default because user edits to exported files would mutate the hidden cache authority.
3. On pure SAF roots, automatic cache and mutable partials SHOULD remain in App-private storage unless a provider-specific cheap-move capability is proven.
4. Private/direct-to-SAF materialization MUST be a single bounded streaming copy; the copy pass MUST establish the destination seal proof without a mandatory second whole-file readback on the Reader hot path.
5. Automatic cache MUST NOT be eagerly migrated merely because the default export root changes.

## 5. Export layout and migration

1. Only materialized user-visible export slots MUST be persisted.
2. Existing materialized slots SHOULD remain stable across verified predecessor/successor updates whenever the verified mapping permits that.
3. Changing the default export root without migration MUST leave old readable manual downloads available; the new root becomes the destination for future materialization.
4. Explicit root migration MUST operate per replica and MUST commit a destination replica before source deletion.
5. Active partial spools MUST NOT move during the same physical transfer generation.
6. Automatic cache MAY remain on the old root/private tier and converge lazily.

## 6. Partial and network continuity

1. A partial is a mutable contiguous transfer spool and MUST NOT be treated as a sealed immutable artifact.
2. Restoring a durable partial SHOULD adopt/reopen the existing spool rather than copy the whole prefix into a second ephemeral artifact when the backend permits it.
3. Local prefix replay and network suffix acquisition MAY run concurrently under the same physical DownloadSession.
4. Network append MUST only extend the authoritative contiguous committed boundary.
5. Reader ingress publication MUST remain ordered from byte zero even if network append advances farther than Reader-local replay.
6. A local loader/transport MUST NOT concatenate an unrelated remote stream after it has already emitted bytes.
7. Strong-validator range resume and validatorless overlap proof remain the only normal continuity authorities. URI/provider scope MUST be respected.

## 7. Read failure feedback

1. Storage read failure MUST be reported with typed cause, access/replica identity, failed offset, and emitted-byte count.
2. Before bytes are emitted, another proven access locator or replica MAY be tried immediately. A cache/repository failure that occurs before any body is exposed MAY fall back to origin in the same transport open.
3. After bytes are emitted, only a proven access path/replica for the same immutable artifact MAY continue from the exact offset without returning to TransferCoordinator. ArtifactCacheTransport MUST NOT splice an origin body behind that committed local prefix.
4. Origin/network fallback after emitted local bytes MUST re-enter DownloadSession/DownloadJob on a later Transfer attempt. The failing persistent read MAY be quarantined for the current transport lifetime so that retry selects origin rather than reopening the same replica.
5. `missing`, `staleLocator`, `shortRead`, and `lengthChanged` MUST invalidate the affected durable binding. `accessDenied` and generic `ioFailure` MUST NOT by themselves delete the binding or physical artifact.
6. Resetting an ephemeral resident artifact-cache projection after body failure MUST NOT delete the external durable cache binding.
7. Normal sealed reads MUST NOT compute whole-file CRC32 on every Reader access. Length/access metadata is the normal hot-path check; explicit repair/audit and materialization/seal boundaries own full checksum work.

## 8. Cross-consumer resource scheduling

1. Pipeline MUST remain Reader-specific and MUST NOT become the scheduler for manual downloads or storage migration.
2. Reader and manual download MUST share physical transfer ownership below Pipeline for identical/resolved physical content.
3. Cross-consumer scheduling MUST be owned by an App-level resource coordinator with separate network, local-read and storage-write capacity domains.
4. Reader foreground demand MAY raise the priority of a transfer also required by manual download; removing Reader demand MUST NOT cancel the manual completion requirement.
5. Storage migration/materialization MUST yield to foreground local reads at bounded chunk boundaries but MUST NOT unnecessarily stop unrelated network transfers.
6. Manual download MUST distinguish `CONTENT_READY` from export materialization completion. Export failure MUST NOT force already-ready content to be re-downloaded.

## 9. Compatibility migration

1. Existing `CacheRec.path` and download-root SQLite representations MAY be read during migration but MUST NOT remain the final logical identity authority.
2. Existing SAF-only and direct-only placements MUST remain readable throughout staged migration.
3. No refactor phase may silently orphan existing pinned/manual downloads, valid partials, or still-readable old roots.
