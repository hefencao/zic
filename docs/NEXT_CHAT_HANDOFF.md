# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.54_android-dependency-closure-runtime-cleanup.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged.
- Ordinary local static-image routing remains renderer-owned and avoids materializing the encoded file in Dart.
- Controlled GIF/WebP tests remain deterministic; Reader promoted-artifact reads still prime at authoritative `DownloadSession.beginRun` and pages remain join-only.
- `ExternalComicPluginFormat` is explicitly imported by `runtime_service.dart` and the dedicated-entrypoint test; the bridge declares its catalog test dependency directly. Do not rely on transitive visibility.
- Mihon/Venera share protocol v1, source adaptation, runtime worker, cancellation, immutable process-private payload staging and process-owned session registry.
- `ExternalPluginRuntimeServiceEndpoint` remains the single dedicated-process method dispatcher. Android has a real non-exported `:zic_plugin_runtime` Service, secondary FlutterEngine entrypoint and lazy bound-service client. Each bind has a generation/death recipient; large packets use root/length/SHA-256 verification. Kotlin still must not duplicate activation/session policy.
- Each activation returns a process generation. Stale service sessions fail before session lookup and are never automatically replayed or reactivated.
- Mihon and Venera production drivers are installed inside `:zic_plugin_runtime`. Mihon loads only the process-private verified APK copy and maps current 1.6 suspend plus old Rx operations; Venera executes the source in a restricted WebView with explicit network/cookie/storage/convert/HTML/image bridges.
- The product source-management screen owns repository discovery and explicit trust/install/update/remove UX through `ExternalPluginController`; external sources remain ordinary `BrowsableComicSource` adapters.
- Mihon repository discovery accepts the current `index.pb`/`repo.json` entry, resolves the full sibling `index.json`, and parses both current `extensionList.extensions` v2 metadata and the legacy array form; do not restore the obsolete `index.min.json` default.
- Venera compatibility must preserve current source return shapes, including `Map`-backed comic/chapter collections, and the official `compute` contract where the evaluated function receives one arguments array.
- Generated Android hosts must expose canonical `https://jitpack.io` from the repository owner that resolves App runtime classpaths; `configure_platforms.py` supports both centralized settings repositories and legacy `allprojects` repositories.
- Manifest restoration accepts only regular format-matching payloads within `external_plugins`; previews, directories, links and paths outside that root are not trusted.
- Mihon code-cache workspaces are activation-specific through `driverId`, deleted after real request drain, and stale roots are cleared when the dedicated Service starts.

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
cd ../plugin_host_bridge && flutter test test/external_plugin_controller_manifest_test.dart test/method_channel_runtime_backends_test.dart test/runtime_service_handler_test.dart test/runtime_service_entrypoint_test.dart
cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest --tests dev.zic.pluginhost.MihonRuntimeWorkspaceTest
cd ../../..
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run Flutter/Dart and Android Gradle builds in the local Android toolchain, then exercise one current Keiyoushi 1.6 extension and one official Venera 1.6 source through browse/detail/chapter/resource.
2. Add Android instrumentation coverage for plugin install, process kill, explicit reactivation and WebView teardown; JVM coverage now protects Mihon workspace uniqueness and stale-root cleanup, but device verification must still prove class-loader/native-library release.
3. Capture incompatible real-world sources as fixtures before expanding API compatibility; never silently return empty catalog data for unsupported ABI or bridge functions.
4. Preserve the existing Home startup stages, Reader demand/artifact ownership, cache coordinator and download session boundaries.
