# Download Storage and Transfer Architecture

Status: Accepted architecture baseline for the storage/transfer boundary refactor.

This document defines the long-term ownership model for Reader page bytes, automatic cache, manual downloads, partial transfers, Android SAF/direct access, version reuse, storage migration, and cross-consumer resource scheduling. `docs/ARCHITECTURE.md` remains the project-wide architecture index; this document owns the detailed download/storage boundary.

## 1. Design goals

The design MUST preserve these properties simultaneously:

- Reader consumes logical pages and immutable Pipeline output; it does not own download storage, fallback, transport, or page-order layout.
- Manual download and Reader may demand the same bytes concurrently without creating duplicate physical transfers.
- Automatic cache, partial transfer state, and user-visible export are different retention/lifecycle concepts even when they can share one physical file.
- Android SAF and direct filesystem access are access methods, not automatically different physical roots.
- Changing storage access mode or default export root must not make still-readable historical downloads disappear.
- Multi-version reuse scales with materialized data and verified version edges, not `version count × page count`.
- No persistent page-order scheme depends on recalculating an `N-index` transform from the newest version's current page count.
- Local prefix restore and network suffix transfer may progress concurrently, but only one physical transfer owner may publish a continuous authoritative byte prefix.
- Pipeline remains Reader-specific. Cross-Reader/manual resource competition is owned below Pipeline by application-level resource coordination.

## 2. Authority layers

The target model has seven separate authorities.

### 2.1 VersionHistory + VersionBaselineResolver

`VersionHistory` owns only source-confirmed/verified predecessor/successor provenance and compact chapter mapping proofs. `VersionBaselineResolver` is the runtime convergence point that projects that history onto explicit heads; consumers do not traverse the historical graph.

For affine predecessor/successor relationships it stores edge facts such as:

- predecessor comic/chapter;
- successor comic/chapter;
- predecessor/successor page counts observed when verified;
- verified offset or another bounded mapping proof.

It does not own files, downloads, Reader order, export slots, or cache retention.

The resolver maintains three distinct facts per unambiguous family: `latestKnownHead` (source-confirmed newest candidate), `shelfHead` (the version actually adopted by shelf/library state), and `downloadHead` (the highest version actually carrying explicit manual-download state). Discovering a newer source version changes only `latestKnownHead`; it MUST NOT silently move shelf or download ownership.

Historical multi-hop edges are allowed only as provenance for shelf/manual selection. When a relevant materialized predecessor can be uniquely verified against the current shelf/download head, the resolver composes that path once into a direct predecessor→head mapping for manual/export consumers. Ambiguous branches or multiple historical paths disable that folding rather than teaching Reader/download/UI to search the graph. Immutable artifact cache is a separate authority: it receives the full source-verified relation set and registered exact-page equivalences, so cache reuse is never gated by `downloadHead` or by whether a version has been explicitly downloaded. Unopened/unmaterialized versions still create only O(V) compact relation state and no page bindings/export rows.

### 2.2 ArtifactRepository

Owns immutable encoded content identity and all known physical replicas.

Conceptually:

```text
logical DownloadId -> immutable artifact -> zero or more replicas
```

A replica records where bytes can be opened and whether it is currently healthy. A logical binding never uses an absolute file path as its identity.

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

`CacheRec.path` is therefore a compatibility representation, not the desired long-term authority. Production schema 7 persists one `artifact_object` row per immutable `artifact_id` plus a durable `storage_root` / `storage_access_locator` registry in the App-private metadata database. `artifact_object` remains the current single physical replica locator/root authority whenever its byte-length/checksum proof agrees with the logical binding, while `cache_entry.path` is legacy fallback only. A proven root may now retain multiple Direct/SAF access locators and durable access health, but this is deliberately not yet `artifact_replica`: one artifact still has at most one indexed physical replica/object locator.

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

Access failure and replica failure are separate facts. `EACCES` may disable DirectAccess while the SAF locator remains usable; it must not by itself invalidate the artifact. Android alias proof first requires the real `Environment.isExternalStorageManager()` grant and only derives a Direct candidate for the system ExternalStorageProvider `primary:` tree. Identity is then proven by a random hidden canary created atomically with Direct `O_CREAT|O_EXCL`, read through SAF, rewritten through SAF only after the exact Direct token matches, and read back through Direct before cleanup; URI/path resemblance alone is never proof and generic/removable/UUID providers remain SAF-only. After durable services open, a successful proof is persisted into schema-7 App-private root/access metadata. Data-plane reads prefer a healthy Direct locator, may fall back to the proven SAF locator without copying bytes, and persist `accessDenied` only against the failed locator so later reads prefer the healthy alias; structural artifact failures remain artifact/replica facts.

### 2.4 ExportLayout

Owns the human-readable manual-download directory, its placement policy, and its currently materialized file slots.

`DownloadPlacement.pageOrder` is an export-layout policy only. Reader never consumes it to reorder logical pages.

The layout persists only slots that actually exist in the user-visible export. It does not expand every historical version into page rows. Production schema 6 stores these sparse slots as `export_page_binding`: logical page identity and logical index are separate from an immutable positive `exportOrdinal`.

`auto` is unresolved intent, not a long-lived physical rule. Before the first structured page materialization it freezes to `chronological` only for a confirmed single-chapter comic with a verified pure-front-prepend page mapping; all other cases freeze to `origin`. Provider/source names and `N-index` arithmetic are not evidence.

For predecessor reuse the layout consumes only direct predecessor→current-download-head mappings produced by `VersionBaselineResolver`. Historical intermediate versions may participate while that direct proof is composed, but ExportLayout itself never traverses them and never creates their page rows. If several predecessors have materialized bindings, the closest compatible/most-complete actual anchor is preferred; relation iteration order is not authority. Existing stable slots remain stable whenever the verified direct mapping permits that; front-prepended pages allocate ordinals after the existing maximum. A layout mutation that would move an existing slot is rejected as policy and requires an explicit export relayout migration.

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

Version discovery alone must remain cheap. A comic with dozens of historical or temporary versions may therefore have many relation edges but no page/export state for versions the user never opens or downloads.

When a materialized version is related to a newly requested version by verified affine edges, compose the edge mappings at request time. Intermediate versions do not need to be loaded or expanded if the stored proof remains sufficient.

Example:

```text
A -> B offset +2
B -> E offset +1
E -> V offset +3

A -> V effective offset +6
```

Only the existing materialized layout and newly materialized pages are updated.

A user-visible export slot is a stable persisted fact once materialized. It is not recomputed from `currentPageCount - sourceIndex` on every newer version.

If the relation cannot be represented by a verified compact proof, ZIC may forgo automatic reuse. It must not create speculative full-version mappings merely to preserve reuse.

## 4. Cache, export and retention

`cache` and `manual download` are retention intents, not necessarily distinct byte objects.

A replica may satisfy automatic-cache retention, manual-export retention, or both.

### 4.1 Direct POSIX root

If automatic cache and manual export are on the same filesystem, a completed cache object may be promoted to a user-visible export with metadata rename (or a safe reflink capability) instead of byte copy.

Hard links are not the default because user mutation of an exported file would mutate the hidden cache inode as well.

### 4.2 Pure SAF root

Automatic cache and mutable partials stay in fast App-private POSIX storage by default. A manual SAF export is materialized exactly once by bounded streaming copy. The copy pass computes/retains the seal proof; normal Reader reads do not re-hash the complete file. Production now makes that distinction explicit: a sealed persistent stream reports `sealedMetadataLength` after locator/existence/exact-length preflight, while a full read that actually recomputes CRC reports `crc32Verified`; joined full reads keep the integrity basis of the source operation that really ran.

SAF cache colocation is not useful unless the provider proves a cheap cross-directory move capability. Current same-directory rename is insufficient.

### 4.3 Lazy convergence after root/access changes

A storage-mode change does not trigger eager movement of all cache data.

- pinned/manual replicas follow explicit migration policy;
- automatic cache normally remains where it is and converges lazily;
- inactive cache may simply age out;
- an active transfer spool never moves during the same physical generation.

## 5. Android SAF and direct access coexistence

A picker-returned `content://` tree is initially a SAF access locator. If All-files access is available, ZIC may derive a candidate direct path only for providers/volumes where this can be proven safely.

The two locators become aliases for one `StorageRoot` only after a bidirectional canary proves they address the same physical directory. Generic document providers must remain SAF-only.

When both exist, direct access is preferred for the data plane; the persisted SAF grant is retained as a fallback.

Changing preferred access from SAF to direct for the same root performs zero byte migration. Existing replica locators remain root-relative.

## 6. Storage-root changes

The durable metadata database belongs in App-private storage and is not conceptually part of a user-selected download root. Production now implements this as `<storage root>/chapter_downloads.sqlite`; `PersistentDownloadArtifactStore` receives its byte `CacheLayout` separately from `SqliteIndex(indexPath)`. A legacy root-coupled `cache.sqlite` is imported once with SQLite `VACUUM INTO` plus `integrity_check`; successful authority switch does not require legacy cleanup to succeed.

A change from root A to root B changes the default destination for future materialization. Existing replicas on A remain valid unless the user explicitly migrates or deletes them.

If migration is requested:

- direct -> direct, same filesystem: rename when safe;
- direct -> direct, different filesystem: one streaming copy;
- SAF -> direct or direct -> SAF, different physical roots: one streaming copy;
- SAF -> SAF: provider move only when capability-proven, otherwise one streaming copy;
- automatic cache normally is not migrated;
- active partial generation is not migrated;
- metadata remains in App-private SQLite.

Each replica migration commits destination authority before deleting the source, so a crash leaves at least one valid replica.

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

Target architecture permits local replay to finish after network suffix transfer starts: network append may advance `committedLength` while Reader-local ingress is still publishing an earlier prefix, and ingress publication remains strictly ordered. Current production implements the preceding exact-POSIX zero-copy spool adoption and same-spool Range resume, but still completes local ingress replay inside local preparation before NetLane admission; replay/suffix concurrency remains a later subphase.

No UI/transport wrapper may concatenate a failed local response with an unrelated remote response after bytes have already been emitted.

Validator rules remain owned by DownloadSession/DownloadJob:

- matching scoped strong validator -> direct range resume;
- no strong validator -> bounded overlap proof;
- validator mismatch/unsafe full replacement -> new network generation while preserving the old valid prefix until the replacement is authoritative.

A physical generation freezes its spool location after it has committed bytes. A Reader-started private spool does not move merely because the user later requests manual download; after completion the resulting immutable bytes may be materialized to the requested export.

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

Before any bytes are emitted, another proven access locator/replica may be tried directly. If repository/cache lookup itself fails before a response body is exposed, ArtifactCacheTransport may fall back to origin in that same open operation.

After bytes are emitted:

- another access locator for the same proven physical replica may continue at the exact offset;
- another sealed replica of the same artifact may continue at the exact offset;
- origin/network continuation must return to TransferCoordinator resume/continuity logic rather than being concatenated inside a Loader/UI adapter.

Permission/access failure never alone invalidates the artifact. `missing`, `staleLocator`, `shortRead`, and `lengthChanged` invalidate the affected durable binding; `accessDenied` and generic `ioFailure` preserve it for later access recovery. Once a persistent body fails after exposure, the current ArtifactCacheTransport quarantines that logical read path for its remaining lifetime so the next Transfer attempt goes to origin instead of reopening the same failed replica. This quarantine never concatenates the origin onto the already-emitted local prefix. Full checksum repair is explicit cold-path work, not a normal Reader hot-read requirement.

## 9. Reader and manual-download resource sharing

Reader and manual chapter commands already share physical transfer ownership. This remains the intended model.

For the same physical transfer:

```text
Reader current demand: high priority, opportunistic display completion
Manual demand: lower priority, required durable/export completion
```

Effective scheduling priority is the highest active consumer priority, while completion intent is the strongest required intent. When Reader leaves, its claim disappears and the same transfer can continue at manual priority without restart.

Network resources therefore remain globally coordinated below Pipeline. Pipeline only translates Reader observation into Reader transfer demand and owns decode/upload/presentation.

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
2. Make persistent artifact Reader hits truly stream from `ArtifactCacheStreamEntry.open()`; remove the full-page `readPage -> Uint8List` local fast path for remote pages.
3. Make durable partials adoptable as the active spool and allow ordered local replay + network suffix concurrency. Exact POSIX active-spool adoption is implemented; SAF/non-capable backends retain streaming-copy fallback, while replay/suffix concurrency remains pending.
4. Introduce StorageRoot + AccessLocator modeling and direct/SAF same-root capability proof. Schema 7 now persists the proven root/access registry and locator health, and ready-artifact reads perform Direct-preferred same-root access fallback without copying bytes; first-class `artifact_replica` ownership remains the next boundary.
5. **Implemented:** move durable download metadata authority to App-private SQLite while retaining one-time compatibility migration from existing root-coupled stores.
6. Split logical artifact binding from physical replica location/health.
7. Replace persistent N-dependent page numbering with sparse materialized ExportLayout + direct VersionBaseline mappings; historical version edges remain provenance only.
8. Replace whole-store directory moves with per-replica, resumable migration and retained multi-root reads.

Each phase must keep compatibility with the preceding durable representation until its own migration is complete.
