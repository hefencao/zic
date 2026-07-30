# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.50_runtime-service-process-generation-compile-closure.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged.
- Ordinary local static-image routing remains renderer-owned and avoids materializing the encoded file in Dart.
- Controlled GIF/WebP tests remain deterministic; Reader promoted-artifact reads still prime at authoritative `DownloadSession.beginRun` and pages remain join-only.
- Report 32 compile blockers are closed with the correct digest sink and explicit async/domain/channel dependencies.
- Mihon/Venera share protocol v1, source adaptation, runtime worker, cancellation, immutable process-private payload staging and process-owned session registry.
- `ExternalPluginRuntimeServiceEndpoint` is now the single dedicated-process method dispatcher. The Android Dart service handler forwards raw messages and maps stable errors; Kotlin must not duplicate activation/session policy.
- Each activation returns a process generation. Stale service sessions fail before session lookup and are never automatically replayed or reactivated.
- Concrete Mihon class loading and Venera JavaScript execution remain fail-closed and unimplemented.

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
cd ../../packages/plugin_host && dart test test/runtime_activation_test.dart test/runtime_service_test.dart test/runtime_worker_test.dart test/runtime_executors_test.dart
cd ../plugin_host_bridge && flutter test test/method_channel_runtime_backends_test.dart test/runtime_service_handler_test.dart
cd ../..
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run the report-32 plugin_host/plugin_host_bridge tests and the full suites in the local Flutter/Dart environment.
2. Add the Android dedicated-service bootstrap that creates the service FlutterEngine and attaches `AndroidExternalPluginRuntimeServiceHandler`; keep the service fail-closed until a driver is installed.
3. Implement the Mihon process driver that loads only the staged APK copy and resolves approved `Source`/`SourceFactory` entry classes.
4. Implement the Venera sandbox driver over the same process host with explicit network, cookie, credential and storage bridges.
5. Add Android service-death integration tests across the real transport: invalidate the old generation, do not replay the failed request, and require explicit reactivation.
6. Preserve Home telemetry without expanding it unless the device issue returns with a captured trace.
