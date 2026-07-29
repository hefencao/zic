# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.39_compile-closure-observable-transition-plugin-gates.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership

- `resource_cache` owns reusable source response policy and optional durable complete `imageBytes`; page artifacts remain
  in `downloads`/sessions/storage.
- `storage_bridge.createAppResourceCache` is the production path/composition factory for the one response coordinator.
  App Widgets do not derive cache paths or instantiate cache policy.
- `downloads` owns promoted page-artifact handoff and read-through artifact transport. Artifact hits and origin fallback
  are observable but still enter normal `DownloadSession -> seal -> promote` work.
- `ReaderView` keeps stable page/media identities. Transition, host lifecycle and first-frame events are correlated with
  page identity and demand revision; Presentation does not add keep-alive, page-byte LRU or adjacent warmup.
- `LiveCoordinator` owns decode/upload scheduling. Demand revisions are retained while work waits in lanes/source
  readiness and are emitted at demand/start/frame state changes.
- `catalog` owns only Mihon/Venera repository metadata and ordinary `BrowsableComicSource` contracts.
- `plugin_host` owns common pre-execution inspection/policy/quarantine/session/runtime-registry rules. Concrete Mihon
  APK/Kotlin and Venera JavaScript executors remain separate and are not implemented.

## Reported dev.38 compile failures closed

- Durable `Uint8List` restoration explicitly casts the validated byte representation to generic `T` before weighting
  and returning.
- Durable maintenance invokes `inspect`/`trimTo` through an explicit `ResourceCacheByteStoreMaintenance` reference.
- `_ReaderPageHost` accepts `super.key`, preserving the stable asset key used to prevent midpoint remounts.

## New regression coverage

- The actual App cache factory is opened twice against one real directory; source and detail covers must restore without
  raw source access on the second start.
- Artifact source, transition midpoint, page host disposal, first frame and decode/upload demand/start/frame ordering
  carry deterministic identities/revisions.
- Plugin gates reject untrusted Mihon signer/ABI and excess Venera capabilities before executor activation, require
  keyless Venera sources to discover a stable key, quarantine activation failures, close invalid sessions and reject
  cross-plugin source identity collisions.

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

cd packages/resource_cache && dart test test
cd ../storage && dart test test/file_resource_cache_byte_store_test.dart
cd ../catalog && dart test test/external_plugin_catalog_test.dart
cd ../plugin_host && dart test test
cd ../downloads && dart test test/artifact_cache_transport_test.dart
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

1. Implement a Mihon Android inspector that verifies downloaded APK hash/signature/package/version and reads extension
   ABI metadata without class loading; then add a separately permissioned executor bridge.
2. Implement a Venera metadata-only JavaScript inspection phase and a constrained runtime exposing explicit network,
   cookie, storage and credential capabilities with cancellation and resource limits.
3. Persist repository trust, quarantine and plugin version state; define signed update and rollback behavior before any
   installation UI.
4. Add deterministic rapid-swipe replay analysis that derives cache-hit, queue wait, decode, upload and first-frame
   durations from the new trace chain; change retention policy only when that evidence identifies the owner.
5. Add memory-pressure shrink/eviction handshakes in pipeline/session/media owners, not Presentation.
