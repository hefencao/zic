# Local replay and download-management invalidation convergence

## Evidence and scope

User reported local-folder chapters appearing under automatic cache, stale management rows until explicit refresh, and Reader loading delays. Device exports were pulled without restarting/reinstalling the running app:

- `.log/zic-debug-trace-2026-09-20T15-33-14.jsonl` (latest, 2,445,681 bytes).
- `.log/zic-debug-trace-2026-09-20T15-28-53.jsonl` (preceding export).

These were recorded by the previous debug installation, not a controlled profile performance run. The trace is evidence of ownership/order and observed symptoms, not a release latency benchmark. Existing SAF/partial worktree changes were preserved.

## Confirmed defects and changes

### Local hot replay caused extra persistence

In the latest trace, the local-folder chapter has 21 pages and zero network response loaders. At t=400–401s, local-document origin responses finish with `session-artifact-handoff / defer-resident-source`: ordinary reading correctly does not create durable artifacts. On reread at t=473–475s, the same identities hit `artifact-byte-cache[-stream]`. At t=476.483s identity `identity:<-50c8739265521a8,540>` reports handoff action `stored`, 18,471,414 bytes. This proves at least one extra body write, not merely a UI label or a reference to the imported original.

`ArtifactCacheTransport` converted every non-durable hot lookup into `ByteResponseDisposition.staged`, losing immutable local replay capability. `DownloadJob` then created ordinary transfer staging, and automatic promoted handoff persisted it. Both streamed and foreground-memory response builders now keep file/content/asset local bytes replayable with **source body authority**, without claiming durable artifact provenance. Remote non-durable bytes retain staging behavior. Explicit `PromotedArtifactCacheHandoff.persist` still materializes a requested offline artifact. Trace cache details now include `artifactDurable` to distinguish hot bytes from persistent ownership; older `sourceClass=persistent-artifact` alone was not durable proof.

Regression: both priority 740 streamed replay and priority 1000 foreground replay wrote a backend artifact before the fix (`.log/local-hot-red.log`). After the fix, ordinary reads create no backend artifact, resident bytes remain readable, and explicit persistence still writes the correct body (`.log/local-hot-green.log`). Transport/handoff focused suite passed 48 tests.

No historical cache record or file was deleted. Some local rows may therefore remain: previous accidental artifacts and explicit offline copies cannot safely be distinguished by `sourceId=local-folder` alone. Hiding all local rows would conceal real occupied space and user-retained downloads.

### Management refresh gaps

Trace route entries at t=456.365s and t=478.952s both adopt 37 Home snapshots and complete post-frame work without durable reconciliation. Only the later explicit refresh at t=487.278s changes the snapshot count to 70. Management mutations emitted while the route was absent had no subscriber; replaying the old Home projection did not repair that gap.

The screen now paints the Home baseline first, resolves services, then requests one reconciliation through Home's existing projection callback. Service generation changes also request reconciliation, and late direct-reader results are generation-fenced. The route does not gain transport/state authority or scan storage before first paint.

Two additional notification defects were reproduced:

- A trailing 120ms debounce could starve indefinitely during continuous writes. It is now bounded coalescing from the first event, with one in-flight read and a pending follow-up.
- `PersistentChapterDownloadService` withheld every management invalidation while *any* manual chapter run was active. It now forwards cheap invalidations immediately; projection consumers own coalescing. A gated download test proves an independent cache write becomes observable before the manual run completes.

Tests prove missed-event catch-up without tapping, first-frame visibility while reconciliation is blocked, and refresh during a continuous 60ms event stream. Red/green evidence: `.log/manager-catchup-{red,green}.log`, `.log/management-event-{red,green}.log`. Home/manager focused suite passed 94 tests. The old static test label asserting no post-frame revalidation was updated; route-first and Home-owned-read assertions remain.

## Loading analysis: distinct boundaries

Analyzers: `tool/analyze_frame_pipeline_trace.py` and `tool/analyze_reader_navigation_trace.py`; outputs `.log/latest-frame-analysis.txt` and `.log/latest-navigation-analysis.txt`.

1. **Extra local I/O is confirmed**, as above. A local reread entered staged resume/handoff despite the complete source already being hot. The fix removes that path, but no device speedup is claimed without a post-fix profile run.
2. **Already-cached pages still require local hydration/decode/presentation.** For the first 424-page Reader session, current page 120 mounts at t=383.555s, the ready-body binding publishes at t=383.979s, local decoder replay follows, and `firstFrameReady` arrives at t=384.410s (855.5ms observed mount-to-first-frame). This is not evidence of an 855ms network fetch. In 100 recorded frame-pipeline samples, 80 designate native decode as the dominant stage and 6 designate source wait; these diagnostic samples are not a representative frame-rate benchmark. The debug trace cannot justify changing waterlines, priorities or network gates.
3. **Offscreen lifetime is not load latency.** JM page 82 mounts at t=406.363s but gets physical ownership near t=411.056s, dimensions at t=411.087s and a first frame at t=411.310s. Its ~4.947s mount-to-frame metric mostly includes time outside active demand. Do not diagnose it as a five-second transfer/decode or expand eligibility to all mounted holders. The initially visible JM pages 88/89 do show ~0.93/0.98s mount-to-frame in this debug run; their release-mode critical path remains a profiling item.
4. **The single `taskFailed` is a separate source-version check.** At t=397.519s, `reader-version-refresh:venera:ehentai` reports `venera-operation-failed: loadResource: Venera resource returned non-image bytes`. The relevant Reader had already produced its first frame at t=392.452s. It is not a local-folder file failure and does not prove the foreground page download failed. The trace lacks response status/body/content-type needed to distinguish source expiry, access challenge or plugin handling.
5. `incremental-decode-failed` retries occur with unsealed prefixes and later frame progress. They are not by themselves proof of corrupted complete files or terminal hangs. Source readiness, decode readiness and presentation readiness remain separate observations; no UI retry owner or new eligibility gate was added.

## Validation

Final command: `LD_PRELOAD=/lib/x86_64-linux-gnu/libsqlite3.so.0 bash tool/check.sh --require-toolchains`.

- Final rerun exited 0 (`.log/local-refresh-final-recheck.log`): 27 Dart/Flutter suites, 1,910 passed; App 339 passed plus 3 existing skips. Analysis gates passed with existing info-level diagnostics. Repository/documentation/ownership/native-header/platform checks passed, Rust format + 22 tests passed, Android debug APKs built for arm64-v8a/armeabi-v7a/x86_64. No `dart format` was run.
- Additional `bash tool/check_android_native.sh` passed for all three ABIs. The canonical full-check APK packaging uses `ZIC_ANDROID_NATIVE=0`; this is not a new release-native performance measurement.
- The first full invocation failed once at `artifact_replica_migration_test.dart:366`, `cleanup debt survives reopen and is retried without moving authority back`, because `retry.sourceCleanupComplete` was false. Its isolated 22-test file passed and the subsequent entire strict check passed. No migration implementation or assertion was changed to hide that failure; intermittent cleanup ordering remains a follow-up, not claimed fixed. Logs: `.log/local-refresh-final-check.log`, `.log/replica-recheck.log`.
- After preserving the original traces, `python3 tool/prepare_reader_device_test.py --mode debug` installed the exact arm64 APK with `adb install -r` and proved current-process durable Home readiness. Bookshelf/Home selected-state round-trip was verified using the proven y=2140 icon input, then manual download management and Canonical cache were opened. No refresh, delete, download or cache-clear button was pressed.
- Post-fix device export: `.log/zic-debug-trace-2026-09-20T23-40-28.jsonl` (device `Download/Debug` same filename). It proves route-open seed **38 snapshots → first frame → service adoption → automatic owner reconciliation → 70 snapshots**; `durable-projection-auto-refresh` is followed by post-frame completion, with no `taskFailed`. The debug reconciliation took ~502ms without blocking the first frame. UI evidence: `.log/local-refresh-{manager,cache}.xml`.

Existing local artifacts remain visible (the sampled row has 4 complete pages and 5 partials, 152 MiB). This run deliberately did not delete them or reinterpret original-file bytes as app cache. New local replay non-copying is covered by deterministic transport/job/handoff tests; post-fix repeated local Reader navigation, release performance and source non-image response recovery are not device-verified.
