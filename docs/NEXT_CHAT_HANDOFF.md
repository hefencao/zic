# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.43_compact-cover-manifest-home-startup-trace-mihon-metadata-bridge.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Flutter mounts `_BootstrapApp` immediately and emits one `home-startup` monotonic trace for bootstrap presentation, durable service stages, visible-cover requests, encoded source origin/length and first decoded frame.
- `PersistentChapterDownloadService.open` remains lazy. Home download badges use one SQLite index projection without restoring sessions or statting page artifacts; exact commands restore exact sessions.
- `EncodedResourceSource` explicitly identifies `memory`, `localFile` and `durableCacheFile`. Ordinary local static files and durable covers use file-backed providers; animations and Reader pages retain their controlled byte/session owners.
- `FileResourceCacheByteStore` loads `response-manifest-v1.json` once. Normal warm hits do not parse one JSON file per cover or read encoded bytes into Dart. Per-entry metadata remains an atomic crash-recovery/migration journal, exact payload length is checked, and LRU touches are flushed as one manifest mutation.
- “Zero copy” means avoiding an avoidable whole encoded-file copy into the Dart heap. Platform image decoders are not claimed to be storage-to-texture copy-free.
- The report-27 compile blockers are closed in product types: no runtime const length, explicit file-store capability narrowing, correct nullable async index fallback, and no nullable bytes passed to byte-owned image players.
- `plugin_host_bridge` implements Android `MihonApkMetadataReader`. PackageManager archive parsing runs on a dedicated worker and returns package name, current signer SHA-256, version code and extension ABI without creating a class loader.
- Venera inspection reads one bounded immutable byte snapshot, derives UTF-8 metadata and SHA-256 from that snapshot, rejects key mismatch and does not evaluate JavaScript.

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
cd ../downloads && dart test test/chapter_downloads_test.dart
cd ../telemetry && dart test test/home_startup_test.dart
cd ../plugin_host && dart test test/payload_inspectors_test.dart
cd ../plugin_host_bridge && flutter test
cd ../../apps/app && flutter test test/library_ui_test.dart test/local_image_preview_test.dart test/home_cover_file_cache_test.dart
cd ../../
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Capture a real `home-startup` trace on the affected Android device and compare bootstrap, service-open, durable/local source readiness and first-frame phases. Do not redirect this diagnosis to Reader telemetry.
2. If service opening still delays Home materially, split root composition into a library/cache-ready Home phase and a later download/queue capability phase without replacing owners inside Widgets.
3. Implement the Mihon isolated class-loader/executor only after the existing signer/version/ABI/capability gate accepts the inspected immutable APK. Add unload and process-death tests.
4. Implement a bounded Venera JavaScript sandbox with explicit network, cookie and storage bridges, CPU/time/memory limits and deterministic per-session teardown.
