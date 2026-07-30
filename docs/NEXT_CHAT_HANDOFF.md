# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.52_binder-death-generation-packet-integrity.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged.
- Ordinary local static-image routing remains renderer-owned and avoids materializing the encoded file in Dart.
- Controlled GIF/WebP tests remain deterministic; Reader promoted-artifact reads still prime at authoritative `DownloadSession.beginRun` and pages remain join-only.
- `ExternalComicPluginFormat` is explicitly imported by `runtime_service.dart` and the dedicated-entrypoint test; the bridge declares its catalog test dependency directly. Do not rely on transitive visibility.
- Mihon/Venera share protocol v1, source adaptation, runtime worker, cancellation, immutable process-private payload staging and process-owned session registry.
- `ExternalPluginRuntimeServiceEndpoint` remains the single dedicated-process method dispatcher. Android has a real non-exported `:zic_plugin_runtime` Service, secondary FlutterEngine entrypoint and lazy bound-service client. Each bind has a generation/death recipient; large packets use root/length/SHA-256 verification. Kotlin still must not duplicate activation/session policy.
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
cd ../plugin_host_bridge && flutter test test/method_channel_runtime_backends_test.dart test/runtime_service_handler_test.dart test/runtime_service_entrypoint_test.dart
cd android && gradle testDebugUnitTest
cd ../../..
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run the report-32 plugin_host/plugin_host_bridge tests and the full suites in the local Flutter/Dart environment.
2. Run the Android JVM packet/binding tests and a real instrumentation service-death test: kill `:zic_plugin_runtime`, verify the outstanding request fails once, stale callbacks do not affect a new bind, and explicit reactivation returns a new process generation.
3. Implement the Mihon process driver that loads only the process-private staged APK copy and resolves approved `Source`/`SourceFactory` entry classes.
4. Implement the Venera sandbox driver over the same process host with explicit network, cookie, credential and storage bridges.
5. Add a full Binder integration test above the inline threshold; the pure packet owner already verifies file routing, SHA-256, deletion, corruption rejection and path confinement.
6. Preserve Home telemetry without expanding it unless the device issue returns with a captured trace.
