# ADR 0341: Replica-scoped explicit download-root migration

Status: Accepted.

## Context

App-private download metadata has been authoritative since the metadata-root split,
and schema 9 already owns durable `artifact_object` / `artifact_replica` migration.
The settings flow nevertheless still used the older `moveChapterDownloadStore()`
algorithm for an explicit directory change: recursively move the byte tree first,
then rewrite all SQLite paths/root ids. A crash between those phases could split
physical bytes and durable authority across the old and new roots. This also
incorrectly treated automatic cache and mutable partial spools as if they were
part of one user-visible export transaction.

`DOWNLOAD_STORAGE_SPEC` already requires the opposite boundary: explicit root
migration is per sealed replica, destination authority commits before source
cleanup, active partials do not move, and automatic cache may remain where it is.

## Decision

1. With App-private chapter metadata, explicit existing-download migration between
   two Direct/POSIX roots uses `PersistentDownloadArtifactStore` as the only
   storage authority. `AppRuntime` must not call the legacy whole-tree mover.
2. The migration selects only verified `READY` bindings protected by explicit
   manual/offline retention (`pinned`). Shared artifact identity is migrated once,
   through the existing schema-9 `migrateArtifactReplica()` protocol, preserving
   `replica_id` and committing the destination locator/root before source cleanup.
3. Automatic-cache-only bindings and mutable partial state remain on their current
   physical root and stay readable through their indexed locators. A root switch
   does not manufacture retention or force mutable transfer staging onto the user
   export root.
4. Existing destination artifact conflicts are proven before any replica authority
   moves. A conflicting target fails the migration rather than overwriting or
   merging unrelated bytes.
5. Structured `.zic.json` manifests are copied to the destination only after all
   selected replicas have committed. The destination manifest is durably written
   and verified before `DownloadPlacement.storageRootId` changes; the placement
   generation advances once for that root commit. Source-manifest cleanup happens
   only after the placement commit and is best-effort.
6. `chapterDownloadDirectoryPendingMoveFrom` plus the explicit
   `replica-direct-v1` protocol marker form the crash-recovery intent. The marker
   is required because an older release used the same source field for legacy
   whole-tree moves; an untagged pending move must continue through that legacy
   recovery path rather than be reinterpreted as replica migration. During a live
   switch, the existing `PersistentDownloadComposition` quiesces its transfer
   owner and migrates with its already-open artifact store. During cold recovery
   startup opens only the persistent artifact store on the recorded source root
   and resumes the same per-replica protocol. Already-committed destination
   replicas are not copied again.
7. If the explicit migration fails, the pending marker is retained and runtime
   reopens the source layout. While that intent exists, Settings reports the
   pending source as the effective directory and only allows retrying the same
   target; it must not mistake the already-persisted target preference for a
   completed switch and clear recovery state. Replica records already committed
   to the destination remain readable by exact durable locator, so retry is
   monotonic rather than a rollback of committed authority.
8. Automatic migration across a SAF boundary remains unsupported. Settings use one
   shared policy predicate and disable the migration option when either source or
   destination is SAF. The existing whole-tree mover remains only for legacy
   pre-App-private metadata adoption/recovery.

## Consequences

- There is no store-wide instant rename guarantee; crash safety comes from durable
  per-replica commits plus a persisted root intent.
- A completed directory switch may intentionally leave automatic cache or partial
  bytes on the former root. Their indexed physical locations remain authoritative.
- The new root becomes the placement/materialization target without conflating that
  decision with cache residency or transfer-spool ownership.
- SAF root migration remains a separate problem because provider replace/locking
  semantics are not equivalent to Direct filesystem relocation.
