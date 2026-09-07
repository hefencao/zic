# Download Storage and Transfer Contract

Status: Accepted normative contract for the storage/transfer boundary refactor.

This document is normative for the detailed download/storage behavior. `docs/SPEC.md` remains the project-wide specification and references this contract.

## 1. Logical identity and version cost

1. Reader page order MUST be the logical manifest order plus explicit Reader presentation settings. Reader MUST NOT inspect `DownloadPlacement.pageOrder` to decide logical order.
2. `DownloadPlacement.pageOrder` MUST describe only user-visible export layout.
3. Durable page placement MUST NOT be recomputed from a global `N-index` rule when a newer comic version changes page count.
4. Unopened or unmaterialized comic versions MUST NOT create per-page artifact/export bindings solely because a version relation was discovered.
5. Historical `ComicVersionRelation` edges MAY remain compact provenance, but Reader, DownloadManager, ExportLayout and download execution MUST NOT traverse them at runtime. A version-state owner MUST project explicit `latestKnownHead`, `shelfHead` and `downloadHead`; discovering a newer version MUST change only `latestKnownHead` until shelf/manual-download state explicitly adopts that version.
6. `ComicPageOrder.auto` MUST freeze before first structured page materialization. It MAY resolve to `chronological` only for a single-chapter comic with verified pure-front-prepend evidence; otherwise it MUST resolve to `origin`. Source/plugin names are not ordering evidence.
7. Materialized export pages MUST have sparse durable positive ordinals. An existing logical page's ordinal MUST NOT change during ordinary incremental/version reuse; a front-prepended page MAY only consume a new ordinal above the existing maximum. A change that would move an existing slot MUST fail as a policy conflict until an explicit export relayout is requested.
8. A unique verified historical path MAY be composed once into a direct predecessor→current-head mapping. Downstream consumers MUST receive that direct mapping, not the path. Ambiguous branches/paths MUST skip automatic folding/reuse. Only an already-materialized compatible predecessor anchor may contribute ordinals, and unmaterialized intermediates MUST remain row-free.
9. `shelfHead` MUST be derived from adopted shelf/library state; `downloadHead` MUST be derived only from explicit manual-download state. Auto-cache-only or merely discovered successors MUST NOT become either head. `downloadHead` MUST NOT gate immutable artifact-cache reuse: cache/artifact ownership MUST consume source-verified version relations/page equivalence independently, while manual/export consumers receive only the direct download-head baseline. Structured image materialization MUST derive its final image extension from bounded byte signatures rather than filename/source hints; JPEG/PNG/WebP/GIF/BMP/TIFF/ICO/AVIF/HEIF are supported signature families, ISO-BMFF requires an explicit AVIF/HEIF brand, and unsupported/non-image bodies MUST fail as artifact corruption.

## 2. Metadata, artifacts and replicas

1. Long-term durable metadata authority MUST live in App-private storage and MUST NOT require moving the metadata database when the user's default export root changes.
2. Logical `DownloadId` binding and physical replica location MUST be separate authorities. During migration, when an existing `artifact_object` row has the same `artifact_id`, byte length, checksum and checksum namespace as its logical binding, its physical locator/root MUST be preferred over the compatibility `cache_entry.path`; a proof mismatch MUST fall back conservatively rather than redirect bytes. Structural invalidation MUST act on the resolved physical locator, while access-only failure MUST preserve the logical binding/artifact identity.
3. A logical artifact MAY have multiple replicas on private, direct POSIX or SAF roots.
4. Access failure on one locator MUST NOT invalidate another locator or the logical artifact.
5. A sealed artifact is immutable. Automatic-cache/manual-export distinction MUST be expressed by retention/export binding rather than requiring duplicate bytes.

## 3. Storage roots and Android access

1. SAF and direct filesystem paths MAY coexist as access locators for the same physical root only after an implementation-owned bidirectional proof confirms they address the same directory; URI/path resemblance or provider naming MUST NOT be sufficient.
2. On Android 11+, a Direct candidate used for alias proof MUST require the current `Environment.isExternalStorageManager()` grant. A permission-settings launch is not itself evidence that the grant exists.
3. A proof canary MUST be created exclusively through Direct access, MUST be read with the exact expected token through SAF before SAF is allowed to mutate it, MUST then be rewritten through SAF and read back through Direct, and MUST be cleaned up. The probe MUST NOT overwrite a pre-existing user file.
4. Generic/unproven `content://` providers MUST remain SAF-only. The current candidate mapper is intentionally limited to the system ExternalStorageProvider `primary:` tree; removable/UUID volumes remain SAF-only until an explicit volume mapping is implemented.
5. A successful alias proof MUST be persisted into App-private root/access metadata when a durable artifact store is active; proof registration MUST NOT migrate bytes or change replica identity. The two proven locators MUST retain one root identity, and locator health MUST remain separate from artifact validity.
6. When direct and SAF locators are both healthy for one root, direct access SHOULD be the preferred data-plane path and SAF SHOULD remain an available fallback.
7. Switching preferred access for the same physical root MUST NOT copy bytes.
8. `accessDenied` MUST degrade the affected access locator, not delete replica/artifact metadata.

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
7. A per-replica relocation MUST preserve `replica_id`. The destination locator MUST belong to the declared `StorageRoot`, and a proven access alias already owned by another replica MUST NOT be used to collapse two replica identities onto one physical copy.
8. Before relocation authority moves, the destination MUST match the sealed artifact's exact length and immutable checksum proof. A complete destination left by an earlier interrupted attempt MAY be adopted only after repeating that proof; a partial destination MUST NOT become authority.
9. Source bytes and sidecar MUST be removed only after the destination locator/root transaction commits. Failure to clean the former location MUST NOT roll back the already-committed destination authority; such cleanup debt MAY be repaired later.
10. Physical replica relocation MUST NOT manufacture logical cache recency or otherwise change logical-binding usage semantics.
11. Migration source reads, destination writes/commit, verification reads and cleanup I/O MUST consume the App-level storage-write capacity in bounded quanta and yield to foreground local reads. This requirement MUST NOT consume or cancel unrelated network capacity.
12. The current relocation primitive MAY discard an interrupted temporary partial copy. Durable partial-copy checkpoint/resume, durable cleanup-debt retry and automatic lazy-migration policy require separate authority before being treated as implemented.
13. Concurrent relocation MUST serialize mutations of the same artifact and the same destination path. Commit-time metadata MUST reject an exact destination locator already owned by another replica; same-root Direct/SAF aliases MUST also be treated as one physical destination across artifact identities.

## 6. Partial and network continuity

1. A partial is a mutable contiguous transfer spool and MUST NOT be treated as a sealed immutable artifact.
2. Restoring a durable partial SHOULD adopt/reopen the existing spool rather than copy the whole prefix into a second ephemeral artifact when the backend permits it. Exact POSIX adoption MUST preserve the existing physical `DownloadSession` identity/epoch/demand/Reader-ingress ownership, MUST use the durable artifact's own index/root, MUST prove a non-link exact indexed length before switching backing, and MUST hold an exclusive busy lease that blocks trim/clear/invalidate/second adoption until that session releases the backing. Adoption MAY defer whole-file checksum work until seal; SAF, verified-equivalent, and non-capable backends MUST retain the bounded streaming-copy fallback.
3. Local prefix replay and network suffix acquisition MAY run concurrently under the same physical DownloadSession.
4. Network append MUST only extend the authoritative contiguous committed boundary.
5. Reader ingress publication MUST remain ordered from byte zero even if network append advances farther than Reader-local replay.
6. A local loader/transport MUST NOT concatenate an unrelated remote stream after it has already emitted bytes.
7. Strong-validator range resume and validatorless overlap proof remain the only normal continuity authorities. URI/provider scope MUST be respected.
8. A page-promotion stall window MUST measure continuous lack of physical progress, not total page duration. Real-time transport cursor or committed-length growth MUST refresh the window even when the growth is below the normal snapshot/trace publication quantum; this check MUST NOT require higher-frequency snapshot publication. For composition-owned transfers, one `DownloadJob` attempt failure MUST preserve an idle/resumable partial while `DownloadTransferOwner` still owns retry; only retry exhaustion may become consumer-visible terminal failure. While the lower physical run is in bounded transport-open or active body-read phase, the page watchdog MUST yield to that lower stall authority instead of racing it with `session.reset()`; owner-level reclaim remains for no-lower-phase/no-progress stalls. A source open MAY exceed the generic 6-second open window only when the exact transport proves a finite lower-layer open deadline; runtime request-plan/load and host response-header deadlines remain separate authorities, while body reads retain the 6-second inactivity watchdog. A cache/read-through wrapper MUST NOT inherit this proof across an unbounded local lookup stage. It MAY keep the generic watchdog through its local phases and, only immediately before entering a proven self-bounded fallback, report a one-shot phase handoff through the same scheduler-owned TaskControl; that report MUST NOT carry timeout values or create retry/scheduling authority. When the generic open watchdog itself expires, it MUST abort only the current controlled-open attempt through an attempt-local control that transparently preserves scheduler priority/priority changes/cancellation; it MUST NOT cancel the scheduler demand. The caller-visible outcome remains a network attempt failure so the physical owner may retry. A local/cache open that completes after this timeout MUST observe the attempt abort before crossing into an origin fallback.

## 7. Read failure feedback

1. Storage read failure MUST be reported with typed cause, access/replica identity, failed offset, and emitted-byte count.
2. Before bytes are emitted, another proven access locator or replica MAY be tried immediately. A cache/repository failure that occurs before any body is exposed MAY fall back to origin in the same transport open.
3. After bytes are emitted, only a proven access path/replica for the same immutable artifact MAY continue from the exact offset without returning to TransferCoordinator. ArtifactCacheTransport MUST NOT splice an origin body behind that committed local prefix.
4. Origin/network fallback after emitted local bytes MUST re-enter DownloadSession/DownloadJob on a later Transfer attempt. The failing persistent read MAY be quarantined for the current transport lifetime so that retry selects origin rather than reopening the same replica.
5. `missing`, `staleLocator`, `shortRead`, and `lengthChanged` MUST invalidate the affected durable binding. `accessDenied` and generic `ioFailure` MUST NOT by themselves delete the binding or physical artifact.
6. Resetting an ephemeral resident artifact-cache projection after body failure MUST NOT delete the external durable cache binding.
7. Normal sealed reads MUST NOT compute whole-file CRC32 on every Reader access. Length/access metadata is the normal hot-path check; explicit repair/audit and materialization/seal boundaries own full checksum work. The byte source MUST expose the integrity basis actually used by stream/full reads; `sourceRead` diagnostics MUST distinguish prior seal proof + current length/access preflight from a CRC recomputed during this read, and a joined read MUST inherit the basis of the operation that supplied its bytes.

## 8. Cross-consumer resource scheduling

1. Pipeline MUST remain Reader-specific and MUST NOT become the scheduler for manual downloads or storage migration.
2. Reader and manual download MUST share physical transfer ownership below Pipeline for identical/resolved physical content.
3. Cross-consumer scheduling MUST be owned by an App-level resource coordinator with separate network, local-read and storage-write capacity domains.
4. Reader foreground demand MAY raise the priority of a transfer also required by manual download; removing Reader demand MUST NOT cancel the manual completion requirement.
5. Storage migration/materialization MUST yield to foreground local reads at bounded chunk boundaries but MUST NOT unnecessarily stop unrelated network transfers.
6. Manual download MUST distinguish `CONTENT_READY` from export materialization completion. Export failure MUST NOT force already-ready content to be re-downloaded.

## 9. Compatibility migration

1. Existing `CacheRec.path` and download-root SQLite representations MAY be read during migration but MUST NOT remain the final logical identity authority. Production chapter metadata MUST open from App-private `chapter_downloads.sqlite`; a legacy root `cache.sqlite` MAY be imported only when the private DB does not yet exist, and the imported snapshot MUST pass SQLite integrity validation before it becomes authority.
2. Existing SAF-only and direct-only placements MUST remain readable throughout staged migration.
3. No refactor phase may silently orphan existing pinned/manual downloads, valid partials, or still-readable old roots.
4. Schema 8 MUST backfill each ready pre-existing immutable `artifact_object` as exactly one `artifact_replica` while preserving the historical first-replica identity (`replica_id == artifact_id`). Mutable partials MUST NOT be backfilled as replicas.
5. A new independent replica MUST NOT be inferred from a logical binding/path update. It MAY become authoritative only after its exact length and immutable checksum proof are verified; a proven Direct/SAF alternate access locator for the same physical root MUST reuse the existing replica identity.
6. Compatibility locator/root rewrites, including an existing whole-root byte migration, MUST preserve `replica_id`. They MAY update the replica locator/root in place but MUST NOT manufacture a second-copy fact.
7. Once all replica rows for an artifact have been structurally retired, compatibility `artifact_object.path` MUST NOT silently resurrect a hidden physical copy.
