# Home runtime binding readiness is not projection readiness

## Reclassification of the reported cold-entry delay

Latest user trace is preserved as `.log/cold-reader-home-adoption-before.jsonl`: 224,283 bytes, 474 events, SHA256 `40b343c3d0f52f3adb5b88786d30d76973d38ed4adfe82d8d2db4d49e2c47122`.

- Core opening starts automatically at **0.029s**, well before Reader input at **2.141s**. `_AppRuntime` schedules this after bootstrap presentation and publishes `HomeServiceHandoff`; its listener starts Home adoption without Reader navigation.
- Download composition takes **3,044,476us** to open; all core services are ready at **3.082s**.
- Reader preparation finishes only at **5.102s**. `serviceHandoffMs=2767`, selected chapter load is 186ms, preparation total 2955ms. The former readiness barrier also joined Home's inventory reload/enrichment and projection publication.
- Page 310 mounts at **5.123s** and presents at **5.681s** (558ms after mount). The dominant remaining user-visible delay precedes mounting.
- Targeted scan completes at **6.716s**, with **169 entries / 7,819 indexed records**; startup reports `protected=7661`.

Previous device performance samples were not equivalent: the connected M2007J1SC's exported profile trace had 38 targeted entries, **1,059 indexed records**, 859 protected records, page 275 and revision-fast-path Home adoption. Its 446–479ms first-frame measurements cannot validate this larger full-reload workload. Core opening still has a separate approximately three-second cost in the supplied trace; this change does not claim to remove that cost.

## Ownership correction

`HomeLibrarySession.adoptServices()` now completes after:

1. Awaiting pre-existing admitted Home initialization/reload dependencies.
2. Opening the incoming library and reading durable canonical projections and version relations **before swapping owners**. Bootstrap snapshot relations must not become unverified Reader reuse proof while Home projection is stale.
3. Replacing the service authority/subscriptions and publishing the version/canonical authority to that adopted runtime.
4. Safely draining old download projection reads and retiring previously owned services.
5. Installing the Home reconciliation tail in the existing `ready` future.

The inventory reconciliation is scheduled on the event queue and stays owned/drained by the same session. It is not joined by capability binding. App's existing handoff then aligns source/cache bindings; Reader composition still joins that narrow handoff before constructing capabilities. No new Reader-owned readiness coordinator, transport state, scheduler gate or service manager was added. Reader does not start the background service open; its explicit ensure callback only joins it (or forces durable creation for an intentionally memory-only empty installation).

`ready` remains the signal for consumers that actually require reconciled Home projection data. Public reload/retry must join the **new** tail after an admitted adoption, not just its captured old `ready`. Close also re-joins `ready` after draining admissions, because an in-flight adoption may install a new projection tail during that drain. Existing ownership is unchanged.

Safety-critical authority-read failure leaves the old bindings intact and rejects adoption. The App background observer reports failures without an unhandled Future error or an automatic same-generation retry loop; explicit callers receive the original error/stack and may retry. A superseding handoff still restarts adoption. If a failure occurs after an authoritative swap, App cache/source bindings remain aligned before propagating that failure; there is no rollback to retired owners.

Telemetry adds `homeServiceReady(stage=home-runtime-bindings)` and the Home log `services-bindings-ready projection=pending`. `services-handoff-complete` continues to denote Home reconciliation completion, not Reader capability readiness.

## Regression evidence

- `.log/home-binding-red.log`: a blocked full-library list keeps the original adoption Future pending; the new requirement fails before the production change.
- `.log/home-binding-green.log`: adoption and a real selected-chapter hydration complete while the full Home list remains blocked; `ready` stays pending until release.
- Failed durable authority read preserves bootstrap bindings; an explicit second adoption succeeds after the error is removed.
- Close during admitted authority preparation waits for the later installed blocked Home reconciliation before completing.
- Existing public reload/retry ordering and old-owner projection-read retirement tests still run. One canonical-projection test now explicitly awaits `ready` before reading the Home list; retry open-count assertions distinguish authority open from a premature retry open.
- `.log/home-binding-focused.log`: initial focused run after ordering fixes passes 85 tests.
- `.log/home-binding-lifecycle.log`: expanded Home session suite passes 69 tests.

## Validation status and limits

The first strict repository run passes after updating the old textual boundary check to require bounded latest-generation retry and explicit failure propagation (`.log/home-binding-full-check.log`). The profile build and device install are recorded in `.log/home-binding-profile-build.log` and `.log/home-binding-device-preflight.log`.

For an explicit full-reload scenario, only the derived Home snapshot was backed up (`.log/home-binding-snapshot-backup.bin`, revision 16831) and its `libraryRevision` made stale. The test did not edit any authoritative database, page body, progress or user preference. Normal Reader checkpoints still update progress/revision through the application. App rebuilt a fresh snapshot normally after the test (revision 16832); the invalidated snapshot is no longer installed. Navigation injection was verified by Bookshelf/Home selected states. A cold-entry tap targeted the previously resolved history card while download composition was opening, not after the preflight readiness wait.

`.log/zic-debug-trace-2026-09-21T15-15-42.jsonl` and `.log/home-binding-full-reload-device.log` verify:

- Core ready at 0.798s; runtime bindings at 0.810s (10,979us binding work).
- Reader preparation at 0.849s, with `serviceHandoffMs=535`; Home full-reload enrichment completes at 1.260s.
- Page 275 mounts at 1.341s, first frame at 1.673s, zero task failures.
- **Residual blocking remains:** the Home bulk query/JSON decode runs continuously for ~304ms, followed by ~97ms of global canonical/version authority construction. The dependency split alone does not prevent shared-isolate CPU blocking.

The additional production correction makes `SqliteImportedLibraryStore.list()` decode detached query rows cooperatively (16 rows or 4ms between real event turns). It does not hold a SQLite transaction/statement across yields, consult Reader state, change network scheduling, or change targeted lookup/atomic backup semantics. A new warm-storage regression verifies an event-turn targeted read and concurrent insert run before bulk decoding completes, while the already materialized list excludes the new row. It fails before the change (`.log/library-decode-yield-red.log`) and passes after (`.log/library-decode-yield-green.log`, all 25 library-store tests).

### Startup recovery query cost

`CacheScanner` probes exact durable path ownership for files encountered during crash recovery. `SqliteIndex.isStorageAccessLocatorAuthoritative()` queried `artifact_replica` by `access_locator`, but the existing composite index starts with `artifact_id`. EXPLAIN on the original production schema reports `SCAN artifact_replica USING COVERING INDEX sqlite_autoindex_artifact_replica_2`. Repeating this per file adds a potentially quadratic lookup cost; it is not Reader-owned work and must not be bypassed with a UI eligibility gate.

Cache schema **20** adds the non-unique `artifact_replica_access_locator` index. The v19 upgrade only creates the index; it does not rerun identity migrations or rewrite authority. Older migration paths also install the index. Fresh and v19-upgrade regressions fail before the fix and now require `SEARCH ... artifact_replica_access_locator`, with the original record/replica retained. Existing scanner, partial, promotion and migration coverage remains enabled. A historical v14 test fixture previously created only `cache_entry`; it now preserves the companion tables a real v14 database has, while rebuilding the legacy logical-binding table under test. Expected latest-version assertions changed to 20; historical migration behavior was not removed.

A host-only synthetic SQLite probe with 7,819 replica rows and 7,819 exact lookups takes 506ms without the index versus 6.05ms with it (`.log/locator-index-synthetic-benchmark.json`). **This is not the user's database or an Android/app benchmark**; logical binding counts are not replica counts. It proves query expansion behavior, not the cause of every millisecond in the supplied trace. `cacheScan.scanMicros` now records scan duration separately for follow-up device evidence. Recovery still completes before the durable store is published, and all authority/deletion rules are unchanged.

### Final verification

- Strict repository check passes: `.log/locator-final-check.log` and `.exit` (0): **27 Dart/Flutter suites, 1,920 passing tests**, 3 existing skips, Rust **22 passing tests**, documentation/ownership checks and Android build/native checks.
- Storage index/scanner/promotion focused tests: **59 pass** (`.log/locator-index-green.log`); startup recovery: **4 pass**.
- Exact profile build (`./tool/build_android.sh profile`, release native) and `adb install -r` preflight: `.log/locator-profile-build.log`, `.log/locator-device-preflight.log`. The device currently runs this profile APK; no uninstall/data clear or cache-body deletion was used.
- Three new forced full-reload cold starts used only backed-up derived snapshot revision invalidation; each exported trace proves the Reader tap preceded core readiness. Snapshots regenerated normally (final revision 16840); no stale test snapshot remains. Test artifacts: `.log/locator-final-device-{1,2,3}.*`, `.log/locator-final-device-results.log`, `.log/locator-final-device-summary.json`.

| Trace suffix (2026-09-21) | Tap | Core ready | Binding ready | Reader prepared | Reader mount | Home enrichment done | First frame | Tap to frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 22-48-49 | 499ms | 577ms | 584ms | 623ms | 785ms | 1,057ms | 1,361ms | 862ms |
| 22-48-58 | 580ms | 645ms | 657ms | 693ms | 873ms | 1,149ms | 1,409ms | 829ms |
| 22-49-07 | 498ms | 620ms | 630ms | 671ms | 829ms | 1,111ms | 1,343ms | 845ms |

All three traces have zero `taskFailed`, page 275, 1,059 indexed records and `protected=859`; recovery scans take 486–516ms. Reader preparation and mounting now precede Home full enrichment, rather than waiting for that projection. First frames still occur after Home enrichment: this does **not** demonstrate complete elimination of shared-isolate contention. The previous dependency-only full-reload sample and these samples have different tap offsets; they are not an end-to-end latency A/B.

One preliminary attempt (`15-29-25`) contained no Reader entry/frame evidence and was discarded rather than counted as a product failure. The later run was classified as early entry from trace timestamps, not from a fixed delay. The initial navigation-control attempt for the final APK also failed its selected-state check; a separate verified Bookshelf/Home round-trip (`.log/locator-*-control-retry.xml`, `.log/locator-home-return-retry.xml`) preceded all final Reader samples.

**Remaining acceptance boundary:** the user's 7,819-index / page-310 workload has not been reproduced at equivalent scale. The missing-index defect is fixed, but its contribution to the user's ~3s core opening is not yet measured on that dataset. Full Home canonical/version authority construction remains synchronous; the tested list decoder yields between rows, not within one oversized JSON/model row. No claim of full resolution of all cold-loading latency is made. Do not reuse smaller-dataset results as acceptance for the user's workload.
