# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.40_managed-artifact-capability-transition-replay.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership

- `resource_cache` owns reusable source-response policy and optional durable complete `imageBytes`; Reader page artifacts
  remain in downloads/sessions/storage.
- `ManagedChapterDownloadService` is the explicit aggregate capability used only where App composition needs chapter
  commands, promoted artifact storage and busy-safe artifact maintenance together. Plain `ChapterDownloadService` stays
  valid for integrations that do not own the artifact plane.
- `storage_bridge.createAppResourceCache` is the production path/composition factory for the one response coordinator.
  App Widgets do not derive cache paths or instantiate cache policy.
- `downloads` owns promoted page-artifact handoff and read-through artifact transport. Artifact hits and origin fallback
  still enter normal `DownloadSession -> seal -> promote` work.
- `ReaderView` keeps stable page/media identities. Midpoint verification is driven by observed host creation/current-page
  state, not a fixed drag distance. Presentation does not add keep-alive, page-byte LRU or adjacent warmup.
- `LiveCoordinator` owns decode/upload scheduling. Demand revisions are retained while work waits in lanes/source
  readiness and are emitted at demand/start/frame state changes.
- `telemetry.ReaderTransitionTraceAnalyzer` reads the existing trace chain and reports artifact source, host remount,
  measured phase durations and missing events. It has no policy or retention authority.
- `catalog` owns only Mihon/Venera repository metadata and ordinary `BrowsableComicSource` contracts.
- `plugin_host` owns common pre-execution inspection/policy/quarantine/session/runtime-registry rules. Concrete Mihon
  APK/Kotlin and Venera JavaScript executors remain separate and are not implemented.

## Reported dev.39 failures closed

- App durable composition now stores the opened persistent service as `ManagedChapterDownloadService`, so it satisfies
  the artifact-maintenance parameter statically without a cast or widening all chapter adapters.
- The Reader midpoint regression no longer expects a target page after an arbitrary 300-pixel drag. It observes target
  host creation while page 0 remains current, then observes the actual midpoint transition and preserves strict one-create,
  zero-dispose expectations for both loaded hosts.

## New regression coverage

- Managed memory chapter services are accepted directly by `ResourceCacheCoordinator` and expose zero-entry artifact
  usage before work.
- `downloads.readerPageTraceIdentity` derives the exact page key and DownloadId prefix used by deterministic replay; App
  code does not reconstruct resource identities.
- Deterministic replay derives cache/origin selection, decode and upload queue/work times, presentation delay,
  transition-to-first-frame time, transition/work revisions, dominant measured phase, JSON-ready output, missing evidence
  and host-remount evidence. A neighbor ready before the midpoint has zero transition wait.
- Rapid-swipe replay separates page/revision transitions and deduplicates repeated transition observations.

## Validation completed here

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

The container has no Flutter, Dart, Cargo, Gradle, Android SDK or Android NDK, so their test/build success is not
claimed. Run the following externally:

```bash
flutter pub get

cd packages/telemetry && dart test test/reader_transition_analysis_test.dart
cd ../downloads && dart test test/chapter_downloads_test.dart test/resource_cache_maintenance_test.dart test/reader_page_identity_test.dart
cd ../resource_cache && dart test test
cd ../storage && dart test test/file_resource_cache_byte_store_test.dart
cd ../catalog && dart test test/external_plugin_catalog_test.dart
cd ../plugin_host && dart test test
cd ../sessions && dart test test/live_coordinator_test.dart
cd ../reader && flutter test test/reader_navigation_test.dart test/reader_controller_test.dart
cd ../../apps/app && flutter test test/resource_cache_restart_test.dart
flutter test test/library_ui_test.dart test/source_browser_test.dart test/reader_controls_test.dart test/app_smoke_test.dart

cd ../../
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run the dev.40 telemetry replay against real rapid-swipe traces and retain the trace plus analysis result; change
   encoded/decoded/texture retention only when the measured owner is identified.
2. Implement memory-pressure shrink/eviction handshakes in pipeline/session/media owners, not Presentation.
3. Implement a Mihon Android inspector that verifies downloaded APK hash/signature/package/version and reads extension
   ABI metadata without class loading; then add a separately permissioned executor bridge.
4. Implement a Venera metadata-only JavaScript inspection phase and a constrained runtime exposing explicit network,
   cookie, storage and credential capabilities with cancellation and resource limits.
5. Persist repository trust, quarantine and plugin version state; define signed update and rollback behavior before any
   installation UI.
