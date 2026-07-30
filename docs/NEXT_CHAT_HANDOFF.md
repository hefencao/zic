# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.48_deterministic-controlled-codec-drain-safe-image-tests.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged. The prior Home delay is not currently reproduced.
- Ordinary local static-image routing is exposed through `localImageDirectFileProvider`; it returns the renderer-owned file provider without materializing encoded bytes in Dart.
- Controlled GIF/WebP playback depends on `FlutterAnimatedCodec`. Production uses `instantiateFlutterAnimatedCodec`; widget tests inject a deterministic codec and do not rely on engine-thread WebP completion.
- Controlled first-frame readiness is emitted only after `WidgetsBinding.endOfFrame`. Target rebuild retains the old frame until the replacement is visible; generation invalidation disposes retained frames.
- Async image and cold-artifact widget tests always unmount in `finally` and yield the real event loop before completion, including failure paths.
- Promoted artifact reads still prime at authoritative `DownloadSession.beginRun`; pages remain join-only.
- Mihon and Venera still share protocol v1, source adapter, runtime worker, cooperative cancellation and Android activation/invoke/cancel/close channels. Android activation remains fail-closed until dedicated isolated drivers exist.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
flutter pub get
cd apps/app && flutter test test/local_image_preview_test.dart test/reader_artifact_cold_open_test.dart
cd ../../packages/downloads && dart test test/promoted_artifact_read_pool_test.dart
cd ../plugin_host && dart test
cd ../plugin_host_bridge && flutter test
cd ../..
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run `local_image_preview_test.dart` alone first and confirm it exits normally after the plain-file provider test; then run the full App suite to detect any unrelated async owner.
2. Run the promoted-artifact and plugin-host suites before changing policy or ownership.
3. Implement the dedicated-process Android Mihon driver behind the existing immutable activation envelope and worker; revalidate payload identity at process entry and load approved `Source`/`SourceFactory` classes only there.
4. Implement the bounded Venera JavaScript driver behind the same worker with explicit network/cookie/credential/storage bridges and deterministic cancellation/close.
5. Add native conformance for process death/service restart without replaying a failed catalog request automatically.
6. Keep Home telemetry available but do not expand it unless the device issue returns with a captured trace.
