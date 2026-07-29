# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.42_file-backed-home-covers-lazy-start-plugin-inspectors.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Flutter mounts `_BootstrapApp` immediately. Durable services open after first Flutter composition; library read-state is loaded in one bulk query and storage failure falls back to the existing memory composition.
- `PersistentChapterDownloadService.open` does not call `restoreIndexed`. Home uses `inspectMany` to project all download badges from one SQLite index list without materializing sessions/page-file checks; exact page commands restore one `DownloadSession`. `materializedSessionCount` exists for diagnostics/regression only.
- `resource_cache` exposes `EncodedResourceSource`. A file-capable durable store returns validated `FileEncodedResourceSource` values and reuses their location within the process. Legacy byte reads remain available for explicit byte consumers.
- `FileResourceCacheByteStore.locate` validates exact key, expiry and byte length without whole-file `readAsBytes`/hash. LRU touches are batched and flushed on close. Atomic write/promotion is the integrity boundary.
- Home covers and ordinary local static images use an engine-facing file provider. Network misses and Android `content://` copy once to durable storage. Animated formats and Reader pages keep controlled byte/session ownership.
- “Zero copy” means avoiding an avoidable full encoded-file copy into Dart memory; platform decoder internals are not claimed to be copy-free.
- Controlled Flutter animation publishes ready only after first-frame presentation and keeps the previous frame during target-only rebuild.
- `plugin_host` now has real immutable-payload inspectors: streaming SHA-256, exact length, Mihon no-class-load metadata boundary and bounded non-executing Venera source-key discovery. Kotlin/APK and sandboxed JavaScript executors remain unimplemented.

## Report 26 closure

- Cold codec phase regression now observes `ready` only after `framePresented` is recorded.
- Gapless target-rebuild regression uses the packaged valid `finite_loop.webp` fixture and still requires a visible `RawImage` before and after target change.
- Cold promoted-artifact regression keeps the direct-cache/origin assertions and advances through actual frames rather than a zero-time loop.

## Validation in the delivery container

Run and record:

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

The delivery container has no Flutter, Dart, Cargo, Gradle, Android SDK or Android NDK. Do not claim their tests/builds without running them externally:

```bash
flutter pub get
cd packages/resource_cache && dart test
cd ../storage && dart test test/file_resource_cache_byte_store_test.dart
cd ../downloads && dart test test/chapter_downloads_test.dart test/promoted_artifact_read_pool_test.dart
cd ../plugin_host && dart test
cd ../../apps/app && flutter test test/library_ui_test.dart test/local_image_preview_test.dart test/reader_artifact_cold_open_test.dart
cd ../../
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Capture a real Home cold-start trace on the affected device: bootstrap service-open duration, visible-cover source (`local-file`, `durable-file`, `network/content-copy`), engine image-cache hit and first decoded frame. Do not redirect this work to Reader trace.
2. If metadata lookup remains dominant with a large visible shelf, add a storage-owned compact response manifest/index loaded once after first paint; do not create a Home-owned cover map.
3. Implement the Android `MihonApkMetadataReader`, then a separately isolated class-loader/executor with signer and ABI tests.
4. Implement a bounded Venera JavaScript sandbox executor with explicit network/cookie/storage capability bridges and per-session teardown.
