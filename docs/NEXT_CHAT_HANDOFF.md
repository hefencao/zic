# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.41_direct-promoted-artifact-read-gapless-cold-decode.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership

- `resource_cache` owns reusable source responses and durable complete image responses.
- `downloads/sessions/storage` own Reader encoded page artifacts, promotion, maintenance and exact page identity.
- `PromotedArtifactReadPool` starts one immutable read of an already-promoted `DownloadId` from the replacement session transport; the Reader media consumer may join it but cannot initiate it. It creates no demand and releases the read when that session is promoted, failed or disposed.
- A reopened Reader may start decode directly from the durable promoted read. The replacement `DownloadSession` still runs receive/seal/promote in the background; Presentation does not gain a page LRU, keep-alive or adjacent-page warmup policy.
- `ArtifactCacheTransport` transfers durable bytes in 64 KiB chunks and uses exact DownloadId plus length for resume identity. Original promotion/storage owns integrity validation. Cache read failure falls back to origin and is traced.
- Flutter animated target-only codec rebuilds retain the last presented frame until a replacement frame is presented. Encoded-byte changes clear the old frame.
- `ReaderTransitionTraceAnalyzer` reports artifact source, durable storage-read time, Reader join time, direct/session-copy consumer, decode/upload/presentation phases, transition/work revisions and host remount evidence.
- `ManagedChapterDownloadService` remains the explicit App-root aggregate for chapter commands, promoted artifact storage and maintenance.
- `plugin_host` still contains shared Mihon/Venera trust, capability, quarantine and session gates only; concrete APK/Kotlin and JavaScript executors remain unimplemented.

## Reported dev.40 failures closed

- `static_demo.dart` explicitly imports the downloads-owned `readerPageDownloadId` adapter; it no longer relies on a re-export to compile.
- The midpoint regression asserts zero loaded-host disposal before gesture release and through the role transition. After settling, normal old-page eviction is allowed, but the two loaded pages must have exactly two mount events total, so a remount is still rejected.

## Cold-open changes

- Page decode no longer waits for durable bytes to be copied into and read back from the ephemeral session artifact.
- Page consumer and cache transport coalesce one persistent read.
- Background cache-to-session transfer is chunked instead of one giant stream chunk.
- The cache validator no longer performs a second full-page hash on the UI isolate.
- Cache read errors fail open through the normal session/origin path.
- Flutter codec emits instantiate/decode/present events with stable DownloadId-derived identity.
- Target-size re-decode is gapless when the encoded artifact is unchanged.

Decoded frames are not persisted across process death. A true cold process must still decode the encoded image; use trace `artifactReadMicros`, decode work and presentation time to determine any remaining delay.

## Validation completed in the delivery container

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

The container has no Flutter, Dart, Cargo, Gradle, Android SDK or Android NDK, so their test/build success is not claimed. Run externally:

```bash
flutter pub get

cd packages/downloads
dart test test/artifact_cache_transport_test.dart test/promoted_artifact_read_pool_test.dart test/promoted_artifact_cache_handoff_test.dart
cd ../telemetry
dart test test/reader_transition_analysis_test.dart
cd ../reader
flutter test test/reader_navigation_test.dart test/reader_controller_test.dart
cd ../../apps/app
flutter test test/reader_artifact_cold_open_test.dart test/local_image_preview_test.dart test/reader_controls_test.dart test/app_smoke_test.dart

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

1. Capture a real cold-process Reader trace on the problematic large page and run transition replay. Separate durable artifact read, Flutter/native decode, upload and presentation before changing retention.
2. If decode remains dominant, add a cache-owned page preview artifact/first-frame placeholder contract in downloads/storage, not a Widget-owned thumbnail cache. Define revision, dimensions, invalidation and budget before implementation.
3. Implement memory-pressure shrink/eviction handshakes in pipeline/session/media owners.
4. Continue Mihon Android metadata inspector/signature verification and Venera constrained JavaScript inspection/runtime as separate plugin-host adapters.
