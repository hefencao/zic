# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.44_visible-frame-artifact-prime-plugin-execution-contracts.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace. The previously reported Home cold-start delay is not currently reproduced, so no eager scan, verbose release trace or speculative startup split was added.
- `FileResourceCacheByteStore` implements the explicit `ResourceCacheFileByteStore` aggregate capability. Stable-file lookup and durable invalidation no longer depend on promotion to two unrelated interfaces.
- Ordinary local static files and durable covers remain file-backed and avoid whole encoded-file copies into the Dart heap. Animations, `content://` and Reader pages retain their controlled byte/session owners.
- Local WebP `ImagePreviewState.ready` now means the first frame was actually presented. Container validation alone cannot publish outer readiness. Target-only codec rebuilds retain the previous frame until replacement presentation.
- `PromotedArtifactReadPool` starts one read when the authoritative replacement `DownloadSession` reaches queued/receiving. Page consumers only join it. The replacement session still receives, seals and promotes the bytes.
- Android Mihon metadata inspection runs off the platform thread and returns package, signer, version, extension ABI, normalized entry classes without class loading.
- `MihonIsolatedExecutor` and `VeneraSandboxExecutor` create exact immutable-payload execution requests with invocation timeout, response-byte, concurrency and runtime-heap limits. They do not implement engines and cannot bypass the existing trust/session gate.
- Venera inspection still reads one bounded immutable script snapshot, verifies length/hash/key agreement and does not evaluate JavaScript.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
flutter pub get
cd packages/resource_cache && dart test
cd ../storage && dart test test/file_resource_cache_byte_store_test.dart
cd ../downloads && dart test test/promoted_artifact_read_pool_test.dart
cd ../plugin_host && dart test
cd ../plugin_host_bridge && flutter test
cd ../../apps/app && flutter test test/local_image_preview_test.dart test/reader_artifact_cold_open_test.dart
cd ../../
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Implement the Android Mihon isolated backend behind `MihonIsolatedRuntimeBackend`. It must load only the exact inspected APK and normalized entry classes, enforce payload hash/signer/package/version/ABI again at process entry, determine Source versus SourceFactory only after isolated loading, adapt returned sources to `BrowsableComicSource`, and deterministically close/unload the runtime. Prefer a dedicated process boundary over placing extension classes in the App process.
2. Implement the Venera JavaScript backend behind `VeneraSandboxRuntimeBackend`. Network, cookies, credentials and storage must be explicit capability bridges; enforce the supplied timeout, heap, concurrency and response-size limits and deterministic session teardown.
3. Define the shared serialized operation/result schema used by both external-runtime adapters without leaking Reader, navigation, demand, `DownloadSession` or artifact APIs.
4. Keep Home startup telemetry available but do not expand it unless the device issue returns with a captured trace.
