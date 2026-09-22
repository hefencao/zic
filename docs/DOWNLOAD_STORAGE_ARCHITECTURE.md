# Download Storage and Transfer Architecture

Status: Accepted architecture baseline for the storage/transfer boundary refactor.

This document defines the long-term ownership model for Reader page bytes,
automatic cache, manual downloads, partial transfers,
Android SAF/direct access, version reuse, storage migration,and cross-consumer resource scheduling.
`docs/ARCHITECTURE.md` remains the project-wide architecture index;
this document owns the detailed download/storage boundary.

## 1. Design goals

The design MUST preserve these properties simultaneously:

- Reader consumes logical pages and immutable Pipeline output;
  it does not own download storage, fallback, transport, or page-order layout.
- Manual download and Reader may demand the same bytes concurrently without creating duplicate physical transfers.
- Automatic cache, partial transfer state, and user-visible export are different retention/lifecycle concepts even when they can share one physical file.
- Android SAF and direct filesystem access are access methods, not automatically different physical roots.
- Changing storage access mode or default export root must not make still-readable historical downloads disappear.
- Multi-version reuse scales with materialized data and verified version edges,
  not `version count × page count`.
- No persistent page-order scheme depends on recalculating an `N-index` transform from the newest version's current page count.
- Local prefix restore and network suffix transfer may progress concurrently,
  but only one physical transfer owner may publish a continuous authoritative byte prefix.
- Pipeline remains Reader-specific.
  Cross-Reader/manual resource competition is owned below Pipeline by application-level resource coordination.

## 2. Authority layers

The target model has seven separate authorities.

### 2.1 VersionHistory + VersionBaselineResolver

`VersionHistory` owns only source-confirmed/verified predecessor/successor provenance and compact chapter mapping proofs.
`VersionBaselineResolver` is the runtime convergence point that projects that history onto explicit heads;
consumers do not traverse the historical graph.

For affine predecessor/successor relationships it stores edge facts such as:

- predecessor comic/chapter;
- successor comic/chapter;
- predecessor/successor page counts observed when verified;
- verified offset or another bounded mapping proof.

It does not own files, downloads, Reader order, export slots, or cache retention.

The resolver maintains three distinct facts per unambiguous family:
`latestKnownHead` (source-confirmed newest candidate),
`shelfHead` (the version actually adopted by shelf/library state),
and `downloadHead` (the highest version actually carrying explicit manual-download state).
Discovering a newer source version changes only `latestKnownHead`;
it MUST NOT silently move shelf or download ownership.

Historical multi-hop edges are allowed only as provenance for shelf/manual selection.
When a relevant materialized predecessor can be uniquely verified against the current shelf/download head,
the resolver composes that path once into a direct predecessor→head mapping for manual/export consumers.
Ambiguous branches or multiple historical paths disable that folding rather than teaching Reader/download/UI to search the graph.
Immutable artifact cache is a separate authority:
it receives the full source-verified relation set and registered exact-page equivalences,
so cache reuse is never gated by `downloadHead` or by whether a version has been explicitly downloaded.
Unopened/unmaterialized versions still create only O(V) compact relation state and no page bindings/export rows.

### 2.2 ArtifactRepository

Owns immutable encoded content identity and all known physical replicas.

Conceptually:

```text
logical DownloadId -> immutable artifact -> zero or more replicas
```

A replica records where bytes can be opened and whether it is currently healthy.
A logical binding never uses an absolute file path as its identity.

Suggested durable concepts:

```text
artifact_object
  artifact_id
  byte_length
  checksum_algorithm
  checksum
  immutable_generation

artifact_binding
  download_id
  artifact_id
  proof_kind

artifact_replica
  replica_id
  artifact_id
  storage_root_id
  relative_locator
  replica_class
  retention_flags
  health
```

`CacheRec.path` is therefore a compatibility representation, not the desired long-term authority.
Production schema 8 keeps one `artifact_object` row per immutable `artifact_id` as the immutable length/checksum proof plus a compatibility locator mirror,
and persists first-class `artifact_replica` rows as physical-copy authority.
The v7→v8 migration backfills every ready pre-existing object as one replica with `replica_id == artifact_id`,
preserving existing failure/trace identity.Mutable partials never enter `artifact_replica`.
Ordinary binding/object locator rewrites may move the compatibility first replica while preserving its `replica_id`,
but they never infer a second physical copy;
an independently materialized replica is registered only after exact length plus whole-file CRC32 proves the bytes match the sealed artifact.
A proven Direct/SAF alternate locator remains an access alias of that same replica/root and is never counted as another replica.
`artifact_replica.access_locator` remains an absolute compatibility locator,
but current reads, destructive retirement, schema-9 migration cleanup and schema-16 sealed/temp cleanup re-resolve its relative path through proven StorageRoot aliases after remount.
A separate root-relative replica schema is therefore HOLD,
not a current correctness requirement and not a reason to reintroduce path identity.

Ready reads now resolve `artifact -> replicas -> proven access aliases`.
A structural preflight/read failure (`missing`, `staleLocator`, `shortRead`, `lengthChanged`) retires only the affected replica;
another sealed replica may still satisfy the logical binding.
`accessDenied` and generic `ioFailure` do not retire the replica.
Once a stream has emitted bytes, automatic locator fallback stays inside the selected replica's proven Direct/SAF aliases;
ZIC does not splice two independently materialized copies mid-stream.
Explicit removal of the final logical binding removes every registered replica's bytes before metadata cascade can orphan physical files.

### 2.3 StorageRootRegistry

Owns physical storage-root identity and one or more access methods for that root.

```text
StorageRoot
  physical identity
  AccessLocator[]
  preferredAccess
  capabilities
```

An Android shared-storage directory may simultaneously expose:

```text
DirectAccess(path=/storage/emulated/0/...)
SafAccess(treeUri=content://...)
```

when ZIC has positively proved both locators address the same physical root.

Access failure and replica failure are separate facts.
`EACCES` may disable DirectAccess while the SAF locator remains usable;
it must not by itself invalidate the artifact.
Android alias proof first requires the real `Environment.isExternalStorageManager()` grant.
For the system ExternalStorageProvider, `primary:` derives its Direct candidate from Android's primary external-storage root;
a non-primary document volume id derives a candidate only from one unique current `StorageVolume.uuid` match with a non-null `StorageVolume.directory`.
Unknown, ambiguous or unmounted UUIDs remain SAF-only,
generic document providers remain SAF-only, and ZIC never guesses `/storage/<uuid>`.
Every candidate is still only a capability hint:
identity is proven by a random hidden canary created atomically with Direct `O_CREAT|O_EXCL`,
read through SAF, rewritten through SAF only after the exact Direct token matches,
and read back through Direct before cleanup.URI/path/UUID resemblance alone is never proof.
After durable services open, a successful proof is persisted into schema-7 App-private root/access metadata.
Re-proving the same SAF tree after a removable-volume mount-path change merges the new Direct locator into the existing `StorageRoot`;
among otherwise-equivalent access methods, the newest verified locator is tried first while older locators remain fallback history.
Data-plane reads prefer a healthy Direct locator, may fall back to the proven SAF locator without copying bytes,
and persist `accessDenied` only against the failed locator so later reads prefer the healthy alias;
structural artifact failures remain artifact/replica facts.

### 2.4 ExportLayout

Owns the human-readable manual-download directory,
its placement policy, and its currently materialized file slots.

`DownloadPlacement.pageOrder` is an export-layout policy only.
Reader never consumes it to reorder logical pages.

The layout persists only slots that actually exist in the user-visible export.
It does not expand every historical version into page rows.
Production schema 6 stores these sparse slots as `export_page_binding`:
logical page identity and logical index are separate from an immutable positive `exportOrdinal`.

`auto` is unresolved intent, not a long-lived physical rule.
Before the first structured page materialization it freezes to `chronological` only for a confirmed single-chapter comic with a verified pure-front-prepend page mapping;
all other cases freeze to `origin`.Provider/source names and `N-index` arithmetic are not evidence.

For predecessor reuse the layout consumes only direct predecessor→current-download-head mappings produced by `VersionBaselineResolver`.
Historical intermediate versions may participate while that direct proof is composed,
but ExportLayout itself never traverses them and never creates their page rows.
If several predecessors have materialized bindings,
the closest compatible/most-complete actual anchor is preferred;relation iteration order is not authority.
Existing stable slots remain stable whenever the verified direct mapping permits that;
front-prepended pages allocate ordinals after the existing maximum.
A layout mutation that would move an existing slot is rejected as policy and requires an explicit export relayout migration.

A logical Reader page and an export slot are distinct:

```text
logical page -> artifact
export slot -> artifact
```

The two bindings may be changed independently.

### 2.5 TransferCoordinator

Owns one physical network/content transfer per resolved physical identity:

- DownloadSession;
- single writer;
- active mutable spool;
- committed contiguous prefix;
- validators and validator scope;
- network suffix/resume;
- retry and transfer lifecycle;
- merged Reader/manual demands.

The current `CompositionDownloadTransferRuntime + DownloadTransferOwner` is the base of this authority and should be preserved rather than replaced by Pipeline logic.

### 2.6 StorageCoordinator

Owns physical I/O operations and migration mechanics:

- open/read/seek;
- append/seal;
- rename/reflink/copy;
- SAF/direct access fallback;
- replica materialization;
- root migration;
- typed replica/access failure feedback.

UI and Reader adapters must not implement their own local-byte/network fallback by concatenating streams.

### 2.7 AppResourceCoordinator

Owns cross-consumer scheduling policy below Pipeline.

It provides separate physical lanes rather than one global semaphore:

```text
NetworkLane
LocalReadLane
StorageWriteLane
MigrationLane (consumes read/write budget)
```

Reader Pipeline continues to own decode/upload/frame resources because those resources do not exist for manual downloads.

## 3. Multi-version materialization without N-index

Version discovery alone must remain cheap.
A comic with dozens of historical or temporary versions may therefore have many relation edges but no page/export state for versions the user never opens or downloads.

When a materialized version is related to a newly requested version by verified affine edges,
compose the edge mappings at request time.
Intermediate versions do not need to be loaded or expanded if the stored proof remains sufficient.

Example:

```text
A -> B offset +2
B -> E offset +1
E -> V offset +3

A -> V effective offset +6
```

Only the existing materialized layout and newly materialized pages are updated.

A user-visible export slot is a stable persisted fact once materialized.
It is not recomputed from `currentPageCount - sourceIndex` on every newer version.

If the relation cannot be represented by a verified compact proof, ZIC may forgo automatic reuse.
It must not create speculative full-version mappings merely to preserve reuse.

## 4. Cache, export and retention

`cache` and `manual download` are retention intents, not necessarily distinct byte objects.
Production schema 11 keeps the compatibility `CacheRec.pinned` bit strictly binding-local:
only an exact logical page that enters explicit manual/offline materialization may set it;
`DownloadPlacement` selects export location/conflict policy and MUST NOT retain later Reader cache pages.
Chapter completion pins only the current manifest exact `DownloadId` set,
never every revision sharing a chapter id.
The v10→v11 one-time migration clears historical placement-derived pins on App-private `final/` cache rows and any pinned partial while preserving already-structured legacy pins.
Older structured rows with no reliable bit remain a read-only compatibility projection until a stronger migration can prove their intent.

A replica may satisfy automatic-cache retention, manual-export retention, or both.
Multiple logical bindings may still share one immutable artifact/replica;
physical deletion remains governed by binding/replica references,
not by copying `pinned` across equivalent versions.
A generalized reasoned-retention table/`retention_flags` is deferred until production has more than one real durable retention owner (for example an explicit user cache-pin distinct from manual export).

### 4.1 Direct POSIX root

If automatic cache and manual export are on the same filesystem,
a completed cache object may be promoted to a user-visible export with metadata rename (or a safe reflink capability) instead of byte copy.

Hard links are not the default because user mutation of an exported file would mutate the hidden cache inode as well.

### 4.2 Pure SAF root

Automatic cache and mutable partials stay in fast App-private POSIX storage by default.
A manual SAF export is materialized exactly once by bounded streaming copy.
The copy pass computes/retains the seal proof;normal Reader reads do not re-hash the complete file.
Production now makes that distinction explicit:
a sealed persistent stream reports `sealedMetadataLength` after locator/existence/exact-length preflight,
while a full read that actually recomputes CRC reports `crc32Verified`;
joined full reads keep the integrity basis of the source operation that really ran.

SAF cache colocation is not useful unless the provider proves a cheap cross-directory move capability.
Current same-directory rename is insufficient.

### 4.3 Lazy convergence after root/access changes

A storage-mode change does not trigger eager movement of all cache data.

- pinned/manual replicas follow explicit migration policy;
- automatic cache normally remains where it is and converges lazily;
- inactive cache may simply age out;
- an active transfer spool never moves during the same physical generation.

## 5. Android SAF and direct access coexistence

A picker-returned `content://` tree is initially a SAF access locator.
If All-files access is available, ZIC may derive a candidate Direct path for the system ExternalStorageProvider:
`primary:` uses Android's primary external-storage root,
while a removable/non-primary volume id must uniquely match the current `StorageVolume.uuid` and use that volume's current `directory`.
Unknown/ambiguous/unmounted volumes and generic document providers remain SAF-only;
no `/storage/<uuid>` path is inferred.

The two locators become aliases for one `StorageRoot` only after a bidirectional canary proves they address the same physical directory.
Re-mounting the same UUID at a different absolute path therefore changes only a proven access locator,
not the durable root identity.

When both exist, direct access is preferred for the data plane;
the persisted SAF grant is retained as a fallback.

Changing preferred access from SAF to Direct for the same root performs zero byte migration.
Persisted replica locators remain absolute compatibility locators;
effective access stays root-relative by deriving the same relative path through proven `StorageRoot` aliases.

## 6. Storage-root changes

The durable metadata database belongs in App-private storage and is not conceptually part of a user-selected download root.
Production now implements this as `<storage root>/chapter_downloads.sqlite`;
`PersistentDownloadArtifactStore` receives its byte `CacheLayout` separately from `SqliteIndex(indexPath)`.
A legacy root-coupled `cache.sqlite` is imported once with SQLite `VACUUM INTO` plus `integrity_check`;
successful authority switch does not require legacy cleanup to succeed.

A change from root A to root B changes the default destination for future materialization.
Existing replicas on A remain valid unless the user explicitly migrates or deletes them.

If migration is requested:

- direct -> direct, same filesystem: rename when safe;
- direct -> direct, different filesystem: one streaming copy;
- SAF -> direct or direct -> SAF, different physical roots: one streaming copy;
- SAF -> SAF: provider move only when capability-proven, otherwise one streaming copy;
- automatic cache normally is not migrated;
- active partial generation is not migrated;
- metadata remains in App-private SQLite.

Each replica migration commits destination authority before deleting the source,
so a crash leaves at least one valid replica.

Production now implements durable per-replica relocation for sealed CRC32 artifacts.
It preserves `replica_id`, serializes relocation by logical binding,
artifact authority and destination path, validates that the destination locator belongs to the declared `StorageRoot`,
rejects a destination that is already a proven access alias of any other replica (including another artifact),
copies through bounded `StorageWriteScheduler` quanta,
and fully verifies destination length + CRC32 before the SQLite authority move.
Direct and the currently writable SAF tree are both supported.
Physical relocation does not refresh logical-binding recency.

Schema 9 adds `artifact_replica_migration` as progress-only state;
it never becomes artifact or replica authority.Its durable state machine is deliberately small:

```text
copying(source remains replica authority, deterministic temp is non-authoritative)
    -> one SQLite transaction moves replica/compatibility authority
cleanupPending(destination is authority, old source/temp are cleanup debt)
    -> cleanup succeeds -> migration row removed
```

The temporary file's physical length is the copy checkpoint,
so migration does not write SQLite on every chunk.
After restart, a non-empty temp is resumable only after its actual length is within the sealed artifact range and the whole temp prefix CRC32 matches the same source prefix.
A proven Direct temp reopens in append mode;
the current Android SAF backend likewise uses `writeAppend`/seek semantics after the same proof.
If the provider cannot prove the old temp length, or if the prefix differs,
the temp is truncated/recreated and copying restarts from zero.
A complete destination left before metadata commit may be adopted only after repeating the full destination proof.

The authority move and `copying -> cleanupPending` transition are one `BEGIN IMMEDIATE` transaction.
Source bytes/sidecar are removed only afterward.
Cleanup failure leaves the destination authoritative and the durable cleanup row intact;
reopening and retrying the same relocation attempts that cleanup again without moving authority back.
Final logical invalidation removes migration-owned non-authoritative temps.
`copying` destination/temp locators may be rebound only when a re-proven StorageRoot shows the same relative path;
`cleanupPending` source cleanup resolves the current proven alias and rechecks immutable proof.
StorageRoot alias merges / legacy whole-root byte moves keep schema-9 root/locator references coherent.

This is still not automatic lazy migration:
no retention policy scans old roots and decides which replicas to move.
Removable/UUID-volume Direct candidate mapping is an access-capability concern resolved from the current Android `StorageVolume` inventory and still requires canary proof;
it does not choose replica placement or retention.
Separate root-relative replica persistence is HOLD because current remount read,
destructive cleanup and schema-9 recovery all recover the same relative locator through proven aliases without a new durable owner.
Mutable transfer spools also remain outside replica migration;
their resume semantics are owned by the transfer-spool architecture.


Crash cleanup for non-authoritative locators is implemented by download-cache schema 16 without changing replica or transfer-spool authority.
Schema 9 remains the only ledger while replica relocation is live:
a `copying` temporary is resumable progress and MUST NOT be treated as garbage.
When final invalidation or structural retirement is about to remove that schema-9 owner,
the generated migration temporary is first transferred to schema16 `temporary` cleanup debt;
`cleanupPending` keeps destination authority while old source/temp are cleanup-only.
Schema 16 adds `storage_cleanup_debt`, a cleanup-only table with three bounded kinds.
`temporary` covers App-created random `.zic-tmp-<timestamp>` / `.tmp-<timestamp>` objects before creation and generated `.zic-migrate-<token>.part` objects only after schema-9 progress authority is being retired.
`obsoleteSealedSource` is allowed only around an already-verified immutable authority switch/retirement:
it records the compatibility locator plus sealed length/checksum proof before metadata can stop naming that source.
`obsoletePartialSource` does not make a mutable spool immutable;
it freezes only the exact old prefix generation at a cross-locator replacement or cold retirement boundary.
The store computes that old prefix's actual length + CRC32 immediately before authority can stop naming its locator,
never on ordinary append/pause/checkpoint.
Ordinary `PhysicalPartialRecord` invalidation/trim instead keeps the row until body plus sidecar absence is confirmed,
so a failed delete leaves the existing partial row as retry authority and needs no debt.
`temporary` and `obsoleteSealedSource` may re-resolve the same relative locator through a re-proven `StorageRoot` alias after remount;
generated-temp identity is checked before deletion,
while sealed cleanup rechecks length+CRC32 and durable authority on the resolved locator.
`obsoletePartialSource` remains deliberately exact-locator/conservative because hot mutable-session authority is not fully represented in SQLite.
A path that has been reused or whose bytes changed loses stale sealed/partial cleanup intent and is never deleted.
`PersistentDownloadArtifactStore.open()` schedules—not awaits—a bounded cleanup drainer after composition construction;
a newly proven access alias explicitly requests another drain,
and `close()` waits through any requested rerun.
Cleanup enumerates only metadata rows, never an SAF tree or filename namespace,
and all I/O runs through `StorageWriteScheduler`.
Cross-locator physical-partial replacement fails closed rather than replacing a longer old prefix with a shorter failed staging prefix;
legacy exact Direct→SAF replacement likewise refuses to forget an old locator whose root cannot be safely inspected.
Normal clean startup still avoids the dirty whole-cache scan.
When `.zic-cache-recovery-required` proves an unclean close,
the bounded `StartupRecovery` scan is only an authority-aware orphan cleanup pass:
a locator named by `artifact_replica`, physical partial/migration metadata or a live owner is protected,
while an unowned final body/sidecar may be removed.
The scan never derives sealed READY authority from final sidecars and never rebuilds READY `DownloadSession`s.
Schema 18 repairs the historical app-side SAF wrapper decode off-by-one without changing byte authority:
the persisted preference remains `saf://<content://...>`,runtime unwraps exactly the `saf://` prefix length,
and only the legacy `/content://...` signature is canonicalized to `content://...`.
The migration rewrites App-private root/access/artifact/replica/promotion/migration/cache/physical-partial/cleanup metadata in place,
never moves body bytes, and converts the malformed `direct /content://...` registry entry into `saf content://... / unknown` rather than fabricating a Direct proof.
Android exact-document-id locator-cache keys apply the same repair only as acceleration hints;
stale provider ids still fail back to ordinary tree resolution.
Schema 17 closes the final rename→SQLite authority gap with `artifact_promotion`,
a progress-only transaction journal.
Begin occurs only after the existing exact/physical partial row carries the sealed length+CRC proof and before `Artifact.promote()` may rename bytes.
The journal names source and destination, exact DownloadId,
optional canonical PhysicalMediaId and storage root;neither locator becomes READY because the row exists.
On every store open (after same-process duplicate-owner rejection, and after dirty orphan cleanup when that scan is required),
recovery checks only journal rows:a matching destination commits metadata;
a matching source with an absent destination is renamed, reverified, then committed;
a foreign/different destination drops the journal and leaves source partial authority intact;
missing/mismatched candidates never manufacture READY.
Final commit is one SQLite transaction that publishes artifact object/replica,
exact READY and canonical physical routing, removes physical partial,and deletes the journal.
`StorageAccessAuthorityQuery` protects both journal candidates from dirty orphan cleanup while the transaction is pending.
Sidecars remain irrelevant to this decision, and schema16 cleanup remains targeted cleanup-only metadata rather than promotion authority or a tree/cache scan.
Side-by-side `physical_media_artifact` READY + same-key `physical_partial` is likewise not a legitimate steady state:
the READY replica is the immutable body authority and the partial is redundant recovery inventory.
`PersistentDownloadArtifactStore` converges this both on READY bind/open and via an asynchronous open-time SQLite key-intersection sweep;
the sweep is metadata-only and never lists Direct/SAF trees.
A physical-partial read/recovery probe is not a cleanup owner:
if `openPhysicalPartialDownload()` observes a same-key READY binding,
it returns no partial and only schedules the existing persistent retirement path;
body/row deletion remains behind physical-artifact→physical-partial serialization plus `StorageWriteScheduler`.
Per-id retirement re-enters physical-artifact→physical-partial serialization,
rechecks the expected READY artifact id, skips a currently borrowed hot partial,
and uses the shared storage-write scheduler.
It deletes and verifies the old body/sidecar before removing the partial row,
so cleanup failure leaves the row as retry authority instead of manufacturing an orphan.
Deferred physical READY LRU touch follows the same artifact→storage-write lock order,
avoiding the inverse-lock deadlock found during the combined sweep/open regression.
Logical inventory is READY-dominant even before background retirement finishes:
Download Manager page projection, persistent usage accounting,
reserved partial bytes and trim candidates ignore a `physical_partial` whose same `PhysicalMediaId` already has READY.
Those read/accounting paths remain non-destructive.
Explicit clear may garbage-collect the redundant partial through persistent maintenance,
but it is not charged or reported as an additional cache eviction.

## 7. Partial transfer architecture

A partial is a mutable transfer spool, not an immutable artifact replica.

Conceptually:

```text
transfer_spool
  physical transfer id
  locator
  committedLength
  totalLength
  validators + validator scope
  generation
```

A restored local prefix and a network suffix belong to the same physical DownloadSession.

The target flow is:

```text
adopt durable spool at length L
       |                         \
       | local ingress replay    \ network resume/probe from L
       v                          v
ordered Reader ingress       append same spool
```

Target architecture permits local replay to finish after network suffix transfer starts:
network append may advance `committedLength` while Reader-local ingress is still publishing an earlier prefix,
and ingress publication remains strictly ordered.
Current production implements the preceding exact-POSIX zero-copy spool adoption and same-spool Range resume,
but still completes local ingress replay inside local preparation before NetLane admission;
replay/suffix concurrency remains a later subphase.

No UI/transport wrapper may concatenate a failed local response with an unrelated remote response after bytes have already been emitted.

Validator rules remain owned by DownloadSession/DownloadJob:

- matching scoped strong validator -> direct range resume;
- no strong validator -> bounded overlap proof;
- validator mismatch/unsafe full replacement -> new network generation while preserving the old valid prefix until the replacement is authoritative.

A physical generation freezes its spool location after it has committed bytes.
A Reader-started private spool does not move merely because the user later requests manual download;
after completion the resulting immutable bytes may be materialized to the requested export.

## 8. Failure feedback

Storage reads report typed feedback to StorageCoordinator/ArtifactRepository.

At minimum:

```text
accessDenied
missing
staleLocator
shortRead
lengthChanged
ioFailure
```

The report includes replica/access identity, failed offset, and number of bytes already emitted.

Before any bytes are emitted, another proven access locator/replica may be tried directly.
If repository/cache lookup itself fails before a response body is exposed,
ArtifactCacheTransport may fall back to origin in that same open operation.

After bytes are emitted:

- another access locator for the same proven physical replica may continue at the exact offset;
- another sealed replica of the same artifact may continue at the exact offset;
- origin/network continuation must return to TransferCoordinator resume/continuity logic rather than being concatenated inside a Loader/UI adapter.

Permission/access failure never alone invalidates the artifact.
`missing`, `staleLocator`, `shortRead`, and `lengthChanged` invalidate the affected durable binding;
`accessDenied` and generic `ioFailure` preserve it for later access recovery.
Once a persistent body fails after exposure, the current ArtifactCacheTransport quarantines that logical read path for its remaining lifetime so the next Transfer attempt goes to origin instead of reopening the same failed replica.
This quarantine never concatenates the origin onto the already-emitted local prefix.
Full checksum repair is explicit cold-path work, not a normal Reader hot-read requirement.

## 9. Reader and manual-download resource sharing

Reader and manual chapter commands already share physical transfer ownership. This remains the intended model.

For the same physical transfer:

```text
Reader current demand: high priority, opportunistic display completion
Manual demand: lower priority, required durable/export completion
```

Effective scheduling priority is the highest active consumer priority,
while completion intent is the strongest required intent.
When Reader leaves, its claim disappears and the same transfer can continue at manual priority without restart.

Network resources therefore remain globally coordinated below Pipeline.
App composition also owns a separate storage-write/migration capacity domain beside the persistent local-read scheduler;
these domains are not folded into `NetLane`.
Storage write/migration work acquires only bounded quanta and must wait when the shared local-read scheduler reports foreground pressure,
so a newly foreground Reader can block the next storage chunk without cancelling an unrelated network transfer.
Durable per-replica copy, prefix verification, destination verification,
commit-adjacent I/O and cleanup all consume this capacity domain;
migration does not consume or cancel unrelated network capacity.
Pipeline only translates Reader observation into Reader transfer demand and owns decode/upload/presentation.

Manual download completion is split into two milestones:

```text
CONTENT_READY
EXPORT_MATERIALIZING
COMPLETE
```

A slow/busy SAF export does not keep network resources occupied and does not force already downloaded content to be fetched again after an export failure.

## 10. Refactor sequence

The migration is intentionally incremental and each functional boundary should be committed separately:

1. Move shared transfer/read scheduling ownership out of Pipeline factory construction into an App-level resource composition owner without changing scheduling policy.
2. Make persistent artifact Reader hits truly stream from `ArtifactCacheStreamEntry.open()`;
   remove the full-page `readPage -> Uint8List` local fast path for remote pages.
3. Make durable partials adoptable as the active spool and allow ordered local replay + network suffix concurrency.
   Exact POSIX active-spool adoption is implemented;
   SAF/non-capable backends retain streaming-copy fallback, while replay/suffix concurrency remains pending.
4. **Implemented:** introduce StorageRoot + AccessLocator modeling and direct/SAF same-root capability proof.
   Schema 7 persists the proven root/access registry and locator health,
   and ready-artifact reads perform Direct-preferred same-root access fallback without copying bytes.
5. **Implemented:** move durable download metadata authority to App-private SQLite while retaining one-time compatibility migration from existing root-coupled stores.
6. **Implemented:** split logical artifact binding from physical replica ownership.
   Schema 8 persists first-class immutable `artifact_replica` rows,
   backfills the old object locator as replica one, permits only proof-verified independent copies,
   and retires structural failures per replica rather than deleting the whole logical artifact.
7. **Implemented:** replace persistent N-dependent page numbering with sparse materialized ExportLayout + direct VersionBaseline mappings;
   historical version edges remain provenance only.
8. **Implemented:** sealed replicas can be explicitly relocated one at a time with stable `replica_id`,
   destination-root/alias validation, bounded storage-write scheduling,
   full destination proof before authority commit, and source cleanup only after commit.
9. **Implemented:** schema 9 persists progress-only replica migration state.
   Direct/current-SAF interrupted copies resume from a physically measured + prefix-CRC32-verified temp,
   unsafe/unprovable prefixes restart from zero, replica authority moves atomically with `cleanupPending`,
   and post-commit cleanup debt survives process restart until successfully retried.
10. **Pending storage policy only when justified by a real owner/need:** automatic lazy migration/retention and retained multi-root convergence.
    Removable-volume Direct mapping is complete, and separate root-relative replica persistence is HOLD because remount read/delete/migration recovery is already closed through proven StorageRoot aliases.

Each phase must keep compatibility with the preceding durable representation until its own migration is complete.
