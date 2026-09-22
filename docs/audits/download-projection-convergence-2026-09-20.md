# Download projection and loading lifecycle convergence

## Evidence and scope

The existing Home button at device coordinates `(500,1535)` exported `/sdcard/Download/Debug/zic-debug-trace-2026-09-20T13-38-52.jsonl`; the pulled copy is `.log/zic-debug-trace-2026-09-20T13-38-52.jsonl` (5,000 events). Export itself already works and was not reimplemented.

The trace contains seven Reader-retention events, six session-disposal completions, incremental decode-prefix retries, and two source-version-check failures. These are separate observations, not proof of one universal loading defect. The installed build mode was not established, so timings are not used as product-performance evidence. The attempted Home/Bookshelf control round-trip did not change the accessibility selected state; no Reader navigation/performance conclusion is drawn from that attempt. The export is independently confirmed by the new device file.

The worktree already contained exact-transfer/SAF partial handoff changes, associated tests/docs, and device-input tooling changes. This change preserves those edits and does not claim their effects as new fixes.

## Confirmed code defects

1. `HomeLibrarySession` replaced download snapshots after asynchronous scans without reconciling events received during those reads. Older byte/page counts, phases, and revisions could overwrite newer progress. Targeted startup publication also used persisted-summary equality as a live-publication gate.
2. Download management/cache-only/startup-targeted reads were not joined before the owned downloads service closed. Deferring work until after a frame did not establish a shutdown boundary.
3. `DownloadManagerScreen` only invalidated service generations on the manual tab, retaining old subscriptions until another user action. A superseded resolver result could transiently rebind to obsolete services. Removing the resolver during an in-flight resolution could leave its retry loop without a resolving capability.
4. Manager live events updated an entry alias without removing older same-chapter revision keys. Row dedup could select an old completed snapshot after a newer revision was cleared. The regression was reproduced before fixing the alias removal (`.log/manager-alias-red.log`) and passes afterward (`.log/manager-alias-green.log`).

## Current behavior

- Home merges only snapshots that changed during a scan. Concurrent chapter events replace all scanned revisions of that chapter, including legitimate stop/delete reductions; there is no max-progress heuristic.
- Targeted reads are fenced by management generation and publish live state independently of durable-summary write suppression.
- Home tracks admitted projection reads by downloads-service identity. Shutdown joins them; retirement of an owned replaced downloads service joins its reads. New scans after close begins are no-ops, and deferred startup work does not start during shutdown.
- Both manager tabs resolve/rebind on service changes. Resolution checks generation before adopting results and stops if its capability is removed. Live chapter events discard older revision aliases before row selection. Reader and NetLane ownership/policy are unchanged.

## Verification

Final command:

```bash
LD_PRELOAD=/lib/x86_64-linux-gnu/libsqlite3.so.0 bash tool/check.sh --require-toolchains
```

Exit 0; full log: `.log/convergence-final-check.log`.

- Repository, documentation, ownership, Android/Kotlin contract checks and native header/libwebp checks passed. The additional `tool/check_android_native.sh` passed.
- All 27 Dart/Flutter package test suites passed: 1,907 tests; App reports 338 passed and 3 existing skips. Analysis gates passed with info-level diagnostics, not a zero-diagnostic claim.
- Rust format check and 22 Rust tests passed.
- Android debug APKs built for arm64-v8a, armeabi-v7a and x86_64. The canonical full check uses `ZIC_ANDROID_NATIVE=0` for this packaging step; this is not a new release-native performance build.
- No `dart format` was run.

Three validation defects were handled separately from product behavior: dev.87's single-line call token now permits whitespace; dev.177 checks the new resolver-capability and generation guards; the Pipeline force-reload test uses a gated durable write to assert the fresh-source quarantine **before** persistence completes, rather than assuming it is still active after an awaited presentation read. Pipeline runtime passes 50 tests. Four pre-existing Rust format-only differences were corrected manually; native semantics are unchanged.

Device smoke acceptance used `python3 tool/prepare_reader_device_test.py --mode debug`, which installed the selected APK with `adb install -r` and observed current-process durable Home readiness. A harmless Bookshelf/Home round-trip was proved via selected tab state using the icon area (`y=2140`); the accessibility-bound center (`y=2198`) did not activate these tabs and was not used as navigation evidence. Then Download Manager opened on manual tasks, switched to Canonical cache, returned Home, and exported a fresh trace at `(500,1535)`.

Post-fix trace: `.log/zic-debug-trace-2026-09-20T15-23-34.jsonl` (device `Download/Debug` same filename; 52 events). It contains route-open projection (70 entries, 37 snapshots), first-frame, service resolution, post-frame refresh completion, Canonical hydration and route-close events, with no `taskFailed`. UI snapshots are `.log/convergence-device-{manager,cache}.xml`. No download/delete/cache-clear command was issued. This validates functional routing/export only, not concurrent-race reproduction or performance.

## Remaining boundary

This is a bounded repair of confirmed publication/lifecycle defects, not a claim that every Reader loading delay or every displayed-progress discrepancy in the application is solved. Source-version-check failures and Reader prefix/decode timing require separate fresh, controlled reproduction. Post-fix device acceptance is limited to the debug functional smoke described above; Reader navigation/decode performance and long-running live-download behavior are not device-verified in this change.
