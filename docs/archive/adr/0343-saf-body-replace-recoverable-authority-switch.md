# ADR 0343: SAF body replacement uses recoverable index-authority switch

Status: Accepted.

## Context

SAF page and partial bodies were staged safely, but replacing an existing target still crossed an unjournaled Android `DocumentFile` window. The old `safReplace` bridge renamed the target to a random `.zic-old-*` name, renamed the staged body into place, and then deleted the backup inside one MethodChannel call. A process death after either rename left Dart and App-private SQLite unable to prove which provider document was authoritative.

This boundary is different from ADR 0342. Structured `.zic.json` commits against `DownloadPlacement`; page and partial bodies are already owned by `CacheRec` or `PhysicalPartialRecord` and must not acquire a second placement authority.

## Decision

1. Generic SAF overwrite is removed. `SafTreeAtomicReplace`, Dart `SafStore.replace`, the Android `safReplace` method, and the delete-then-rename compatibility fallback are not production capabilities. The low-level `commitSafTemporary` helper may rename only into an unused target.
2. A page/partial replacement stages and verifies the complete candidate first. Before mutating an existing target, the metadata owner flushes one App-private body intent under `<index>.saf-body-transactions/`. The intent records the exact tree URI, target, staged temporary, deterministic `target.zic-old` backup, whether a target existed, the expected post-commit index record, and the staged body proof.
3. The existing index record is the only commit point. READY pages commit through `CacheRec`; exact partials commit through their new `CacheRec`; canonical physical partials commit through `PhysicalPartialRecord`. New partial rows persist the CRC32 already accumulated while staging, and recovery compares stable content/locator authority fields rather than mutable `touchedUs`/pin projections; equal length alone is never commit evidence.
4. Replacement order is intent flush -> old target to deterministic backup -> staged body to target -> target verification -> existing index authority commit -> backup/temp/intent retirement. A failure before index commit rolls back to the old target. A failure after index commit keeps the new verified target and only finishes cleanup.
5. Startup body recovery runs after the metadata process owner is acquired and before cleanup-debt scheduling. It enumerates only the App-private intent directory and probes the exact SAF paths named by each intent; it does not enumerate the SAF tree.
6. Transient staging temps and resumable replica-migration temps have different lifecycle owners. A transient SAF staging temp holds an in-process active lease so cleanup debt cannot reclaim it while the writer still needs it. On process death that lease disappears while durable cleanup debt remains. Replica-migration temps do not use this lease because their temp is itself resumable durable state.
7. Local intent `.tmp` files are ignored by runtime intent readers. Only store-open recovery, while the metadata process owner is held and before business writers start, retires orphan `.tmp` journal staging files. This prevents one concurrent page transaction from deleting another transaction's intent while it is being flushed.
8. Partial validator sidecars remain non-authoritative acceleration metadata. They may be replaced independently; losing a sidecar cannot change body/index authority.
9. ADR 0342 remains the manifest/placement protocol. Body recovery MUST NOT use `DownloadPlacement` generation/fingerprint as a body commit token.
10. Replacing an identical partial can match the expected stable index authority before the new commit. If its target is absent, recovery may restore the deterministic backup only after an independent full length+CRC proof matches that same current authority. A present unknown target is never overwritten by this path. Reopened/stale intents and exception recovery verify full CRC even for partials; only cleanup immediately following the same live staging and index commit may reuse its accumulated copy proof without another body scan.

## Recovery contract

- old index + backup only restores the old target and removes an abandoned staged temp;
- old index + new target + backup rolls back even when old and new bodies have equal length;
- committed expected index + new target + backup keeps the new target and retires the backup;
- an uncommitted first target is removed rather than adopted;
- a committed target that disagrees with the intent proof fails closed;
- malformed body intent aborts open but releases metadata process ownership;
- concurrent runtime intent readers never delete another live `.tmp` journal staging file.
- identical exact/physical partial authority + backup only restores the verified current body without rotating index authority;
- a same-length backup with different CRC cannot replace a missing committed target;
- same-length target changes fail closed during both committed and uncommitted recovery, preserving target/backup/intent;
- a refused current-backup rename preserves intent and releases process ownership for a later recovery attempt;
- normal partial staging and successful commit do not rescan the body for cleanup.

## Validation status

The focused body suite passes 16/16, including same-authority backup-only restore, same-length CRC mismatch fail-closed, refused-rename owner release and zero additional body scans for live partial commit. The downloads suite passes 504/504 with replica-migration resumable-temp and structured-page paths included. The repository required-toolchain gate passes, including all analyzers/ownership guards, Dart/Flutter suites, three-ABI Android builds and Rust media_core 22/22.

[Device evidence](../audits/saf-body-kill-reopen-2026-09-30.json) covers API36 M2007J1SC's real ExternalStorage DocumentsProvider using an existing persisted grant and isolated fixture/private index: exact and growing physical partials pass backup/install/index-commit process-death recovery, identical exact partial passes backup-only recovery, and same-length target tampering fails closed before or after index commit. Nine kill/reopen cases and one physical equal-length no-op pass. The isolated fixture is removed and the original APK restored with matching SHA256. Current physical equal-length admission skips replacement; same-authority physical backup recovery remains a deterministic cold-intent contract. This evidence is scoped to the tested provider and process death, not sudden power loss or every provider.
