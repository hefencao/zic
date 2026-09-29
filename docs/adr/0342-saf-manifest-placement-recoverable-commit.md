# ADR 0342: SAF manifest/placement recoverable commit and metadata process ownership

Status: Accepted.

## Context

Structured SAF exports previously wrote `.zic.json` through the generic temp-file/`safReplace` path and then updated `DownloadPlacement` in App-private SQLite. The store serialized one manifest path only inside one Dart object. A second process could open the same private metadata, treat another live process's recovery marker as crash evidence, and run recovery concurrently. The Android `safReplace` implementation also uses an old-target rename window that is not a provider transaction.

The manifest already carries a monotonic `generation` and content `fingerprint`, and `DownloadPlacement` mirrors the last committed token. Those tokens identify the commit point, but they are not sufficient to prove that an otherwise valid newer SAF target was written by zic rather than changed externally. Therefore recovery also needs explicit App-private transaction intent written before SAF mutation.

## Decision

1. `PersistentDownloadArtifactStore` is the single process owner of one App-private download-metadata database. It acquires an in-process absolute-index-path owner and a non-blocking OS `FileLock` on `<index>.owner.lock` before opening SQLite or running recovery. Clean or failed close releases both owners.
2. SAF `.zic.json` no longer uses the generic replacement primitive as its transaction boundary. Before any SAF target/backup mutation, the metadata owner writes and flushes one App-private intent under `<index>.saf-manifest-transactions/`. The intent binds tree URI, exact manifest path, owner IDs, the old placement token, the old manifest token when present, operation (`replace` or `delete`), and the new manifest token for replacement.
3. `DownloadPlacement` remains the commit point. For replacement, the old manifest is retained as deterministic `.zic.json.zic-old`, the new target is installed and verified, then the exact new generation+fingerprint is committed to placement. For final deletion, the old manifest is first renamed to the deterministic backup and placement is then removed. Backup and intent cleanup occur only after the placement commit point.
4. Recovery is intent-driven, not generation-driven. If placement still matches the old placement token, replacement rolls back (restore the old manifest or remove an uncommitted first target) and deletion restores the backup. If placement matches the new replacement token, replacement keeps the verified new target. If placement is absent for a delete intent, deletion is committed and target/backup cleanup continues. Any other placement state fails closed as ambiguous.
5. A valid newer target without a durable intent MUST NOT advance placement merely because its generation is higher. This prevents external or unrelated file changes from being mistaken for an interrupted zic transaction. A placement generation newer than the manifest remains legal; the next writer uses `max(manifest.generation, placement.generation) + 1`.
6. Reads wait for the in-store structured-write tail for that exact manifest path, so the same process cannot observe the temporary target/backup window as a committed manifest.
7. Startup enumerates only the small App-private pending-intent directory, then performs exact-path probes for legacy deterministic backups referenced by persisted placements. It does not enumerate the SAF tree. Legacy backup recovery is allowed only when an exact placement token matches the target or backup; it never uses a target-ahead heuristic.
8. This decision closes only the structured manifest/placement owner boundary. Generic page/partial `SafTreeAtomicReplace` still depends on DocumentFile rename behavior and has no equivalent durable journal. It remains governed by DL-DIR-019 and MUST NOT be described as atomic or crash-complete.

## Validation contract

- a second process cannot acquire the private metadata owner while the store is live, and can acquire it after clean close;
- a second store in the same process cannot own the same absolute index path through a different byte root;
- a valid newer target without an intent does not change placement;
- first-manifest target + old placement + replace intent rolls back by deleting the uncommitted target;
- old-placement/new-target/old-backup + replace intent rolls back;
- new-placement/new-target/old-backup + replace intent rolls forward;
- corrupt stale backup does not invalidate a committed target;
- corrupt uncommitted target restores the committed backup;
- old placement + delete intent restores the backup, while absent placement + delete intent completes deletion;
- normal replacement and final deletion retire their intents and do not call generic `SafTreeAtomicReplace`.
