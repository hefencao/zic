# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.49_process-entry-payload-staging-target-rebuild-regression.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged.
- Ordinary local static-image routing remains renderer-owned and avoids materializing the encoded file in Dart.
- Controlled GIF/WebP tests use deterministic codecs. The target-rebuild regression now uses a 2048×2048 VP8X canvas and first proves that two distinct downsample targets were requested.
- Reader promoted-artifact reads still prime at authoritative `DownloadSession.beginRun`; pages remain join-only.
- Mihon/Venera still share protocol v1, source adaptation, runtime worker, cancellation and Android platform channels.
- `ExternalPluginRuntimeProcessHost` now reparses activation messages, stages an exact process-private payload copy, owns runtime sessions and never replays interrupted requests after process restart.
- Sessions remain charged to the process limit until the driver really closes; process shutdown rejects and cleans any activation still crossing verification/driver creation.
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
cd ../../packages/plugin_host && dart test test/runtime_activation_test.dart test/runtime_worker_test.dart test/runtime_executors_test.dart
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

1. Run `local_image_preview_test.dart` alone and verify the large-canvas target rebuild test exits normally, then run the full App suite.
2. Integrate `ExternalPluginRuntimeProcessHost` into the dedicated Android service transport rather than duplicating activation/session policy in Kotlin.
3. Implement the Mihon process driver that loads only the staged APK copy and resolves approved `Source`/`SourceFactory` entry classes.
4. Implement the Venera sandbox driver over the same staged-payload/session host with explicit network, cookie, credential and storage bridges.
5. Add Android service-death conformance: invalidate the old session, do not replay the failed request, and require explicit reactivation.
6. Preserve Home telemetry without expanding it unless the device issue returns with a captured trace.
