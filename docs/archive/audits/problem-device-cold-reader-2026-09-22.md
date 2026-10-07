# Actual-device cold Reader blocking: SQLite bulk work and redundant recovery stats

## Preserved incident

The operator connected the actual failing device, **25113PN0EC, 1220×2656**. This is not the earlier M2007J1SC small-data device. Evidence lives under `.log/problem-device-2026-09-22/`.

- Original export: `zic-debug-trace-2026-09-22T00-51-29.jsonl`, 188,281 bytes, 449 events; SHA256 `d1c3feacd8909286492862d296c1f56cbf5fc97828c49456cb83d0f3a2a6f8f9`.
- Original logcat, startup log, installed APK and its path were captured before restarting/installing anything. Installed APK SHA256: `05ca881180838f6ff750951c46c9b23bac3465efa712d34a8080acaf4aeb5242`.
- Original application was **Release**, not debug. Its arm64 `libapp.so` and `libflutter.so` match the local arm64 release output. `run-as` was unavailable on this release build; this was not treated as a successful private-data read.
- Original data: **379 entries, 169 targeted download entries, 7,819 index records, page 310**, `protected=7661`.

Original timeline (trace clock):

| Event | Time |
| --- | ---: |
| Background core opening | 0.040s |
| Reader tap | 0.817s |
| Recovery scan ends | 1.977s (scan itself 1.860s) |
| Core ready | 1.978s |
| Runtime bindings ready | 2.001s |
| Reader preparation done | 2.187s |
| Reader mount | 2.927s |
| Home enrichment done | 3.747s |
| First frame, page 310 | 4.597s |

Tap to first frame: **3.780s**. No `taskFailed`; absence of errors did not imply acceptable loading. Preparation included 1,181ms handoff and 162ms hydration. Startup logs show ~726ms blocking around the primary query batch, ~235ms canonical authority construction and ~48ms version authority construction. Background snapshot writing/projection also overlap loading.

## Corrections and ownership

### Persistent bulk SQL and decoding off the UI isolate

Previously `SqliteImportedLibraryStore.list()` synchronously materialized the entire SQLite result before its cooperative row decoder could yield. The previous fix therefore did not cover native SQLite/UTF string transfer, nor a single oversized JSON row.

Persistent bulk list now uses a short-lived, storage-owned isolate with its own **read-only** connection. Only the database path is captured by a top-level helper; no Home, Reader, mutable index or connection crosses into the worker. SELECT plus JSON/model decoding finish there; completed models transfer back. The connection is always disposed. A bounded SQLite busy timeout handles concurrent writer-open/final-WAL-checkpoint locks off the UI isolate. Errors remain observable to the list caller. Store close rejects further valid reads by releasing its existing connection and drains admitted list computations; it does not promise to wait for arbitrary caller continuations.

In-memory lists keep the detached-row cooperative decoder. Exact chapter reads, atomic backup transaction semantics, migrations and the existing progress writer are unchanged. Reader owns no new state or worker; this is not a network eligibility gate or a second scheduling authority.

Regression: one persistent chapter with 3,000 pages must allow an event turn before list completion, including concurrent close. It fails before the change (`bulk-red.log`) and passes after. Another regression verifies malformed JSON propagates to the caller, close still completes, and a post-close list rejects. Existing in-memory query-snapshot/concurrent-insert coverage remains enabled. An early test incorrectly required the caller's `.then` to run before close; that listener ordering is not the storage resource-lifetime contract and was not enforced with an artificial production delay.

### Recovery sidecar stat amplification

Added `ScanReport.phaseMicros` / `cacheScan.phaseMicros` to separate preparation, temporary metadata, metadata, body cleanup and partial validation. The diagnostic profile run (`01-07-59`) showed:

- Total scan 2,501,853us.
- Metadata phase **2,288,524us**.
- Temporary metadata 158,059us; body cleanup 44,096us; partial validation 1,197us.

For each DB/live-owned `.meta`, the scanner repeated a serial filesystem type query on the body before adding it to `managedData`. Ownership had already established preservation, and the later body pass would also preserve that path by authority regardless of type. This extra filesystem round-trip per owned sidecar was not an authority check.

The scanner now adds a **scan-local conservative preservation hint** directly after the existing ownership check. It does not infer body existence, integrity or type. Missing mutable partials still receive independent actual-file validation; body/journal authority, orphan deletion, symlink rejection, temporary-sidecar repair and promotion ordering remain intact. A strengthened regression gives a missing partial an owned sidecar: its absent body still retires the partial binding, and the next scan deletes the now-unowned sidecar. Sidecars cannot manufacture durable authority or leave a persistent preservation cache.

No DB owner rules, crash-recovery admission or NetLane policies were bypassed. Core still opens in the background and Reader still joins safe runtime binding, not Home inventory completion.

## Same-device validation

Build: `./tool/build_android.sh profile` (**Profile Dart + release native**), installed with `adb install -r` through `tool/prepare_reader_device_test.py --mode profile`. Logs: `profile-build.log`, `profile-build-2.log`, `device-preflight.log`, `preflight-2.log`. Original Release APK remains preserved locally. No app-data clear, uninstall or cache deletion was used. After installing profile, the stopped app's library/download DB and WAL were also backed up read-only into `database-backup/`.

Navigation injection was verified on this device using actual Home/Bookshelf selected states (`*-control-2.xml`), not coordinates copied from the older phone. Tests resolve the history card and export button from accessibility bounds, use explicit display 0, and require exported Reader mount/frame evidence. Two early **invalid test attempts** used negative snapshot revision `-1`, which the snapshot parser rejected; their empty-bootstrap traces (`01-14-21`, `01-15-08`) were discarded. They do not establish a Reader failure. The app regenerated valid derived snapshots; no authoritative data was edited. The corrected procedure uses valid stale revision **0**, with a per-run backup and restoration on failure if regeneration has not completed.

All six accepted runs force the Home full-reload path by changing only the backed-up derived snapshot revision. Application checkpoints update progress/revision normally; the tests do not modify pages, user preferences or authoritative DB rows. Final regenerated snapshot revision is 4010. Each accepted export confirms **7,819 index records, page 310, protected=7661, zero taskFailed, zero removedRecords and zero deletedOrphans**.

| Trace suffix, 2026-09-22 | Tap | Core ready | Tap → first frame | Scan | Home enrichment done | First frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 01-17-28 | 544ms | 319ms | **330ms** | 270ms | 1,611ms | 874ms |
| 01-17-40 | 578ms | 281ms | **328ms** | 209ms | 1,652ms | 907ms |
| 01-17-53 | 559ms | 257ms | **320ms** | 201ms | 1,677ms | 879ms |
| 01-18-46 | 241ms | 488ms | **557ms** | 371ms | 1,837ms | 798ms |
| 01-18-58 | 182ms | 307ms | **440ms** | 234ms | 1,702ms | 623ms |
| 01-19-11 | 187ms | 311ms | **410ms** | 231ms | 1,799ms | 597ms |

The last three are genuine early entries, established by timestamps rather than waiting for readiness. All six first frames precede Home enrichment completion; the costly full-list query no longer keeps the UI isolate from mounting/presenting Reader. The data scale and selected page now match the incident, unlike previous small-data acceptance attempts.

These are app-cold (`am force-stop`), not kernel-page-cache-cold or device-reboot measurements. Baseline was Release and verification is Profile, both release-native, so this is not a tightly controlled percentage-speedup benchmark. Global canonical/version construction and snapshot encoding still have synchronous portions; this change does not claim every later frame/jank problem is solved.

## Repository verification

Focused storage tests: **35 passed** (`storage-focused-final.log`). A later strict-gate run reached 446 Dart tests and failed at `packages/downloads/test/persistent_artifact_failure_test.dart:173` (`direct cleanup debt drains asynchronously without blocking store open`, expected pendingCount 1, actual 0); Rust was not reached. This is a known timing-sensitive test also recorded in the prior local-replay audit. Three focused reruns passed (32/32 each), the current diff does not touch `_scheduleCleanupDebtDrain` or `StorageWriteScheduler`, and the final full-gate retry passed: 1,922 Dart tests, 3 existing skips, Rust 22 tests, no failures. The first full-gate miss is retained as an existing flaky observation, not a product regression. Profile remains a performance measurement, not a Release-vs-Profile benchmark. Final full-gate log: `/tmp/pi-bash-9f850cda73a34e8f.log`.
