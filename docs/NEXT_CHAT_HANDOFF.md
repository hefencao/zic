# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.47_runtime-worker-cancellation-platform-backend-channel.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged. The prior Home delay is not currently reproduced; no eager scan, prewarm or verbose release logging was added.
- dev.46 local-image and cold-artifact behavior remains: one renderer-owned `FileImage` stream, actual frame readiness, explicit widget teardown, and promoted artifact priming at authoritative `DownloadSession.beginRun`.
- Mihon and Venera share protocol v1, one `ExternalPluginRuntimeSession` source adapter, raw message-channel/handshake transport and now one isolated-side `ExternalPluginRuntimeWorker`.
- The worker reparses requests inside the isolation boundary, rejects unknown sources and duplicate active request IDs, sanitizes driver errors, owns cooperative cancellation and drains real work on close.
- Host timeout may send request-level cancellation, but the invocation permit remains held until the underlying channel Future exits.
- Execution activation messages carry the exact inspected payload path/length/hash, approved capabilities and complete limits. Android host adapters expose activation/invoke/cancel/close through one platform channel.
- Android native activation currently fails closed because the dedicated isolated APK/JavaScript service is not implemented. It must not fall back to main-process class loading or unrestricted JavaScript.
- Runtime messages contain only protocol-safe primitives, maps/lists and `Uint8List`; Reader, navigation, demand, `DownloadSession`, cache maintenance and artifact objects do not cross the boundary.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
flutter pub get
cd packages/downloads && dart test test/promoted_artifact_read_pool_test.dart
cd ../plugin_host && dart test
cd ../plugin_host_bridge && flutter test
cd ../../apps/app && flutter test test/local_image_preview_test.dart test/reader_artifact_cold_open_test.dart
cd ../..
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Run plugin-host and bridge suites first, including worker conformance, cancellation, joinable close and method-channel envelope tests.
2. Implement a dedicated-process Android Mihon service behind the existing activation/channel contract. Revalidate exact payload identity at process entry, create the class loader only there, discover approved `Source`/`SourceFactory` entry classes and adapt calls through `ExternalPluginRuntimeDriver` plus the shared worker.
3. Implement a bounded Venera JavaScript service behind the same contract, with explicit network/cookie/credential/storage bridges, cooperative cancellation checkpoints and deterministic driver close.
4. Add native end-to-end conformance for malformed handshake/response, duplicate runtime source identity, large binary resource, cancellation races, process death and service restart.
5. Keep Home startup telemetry available but do not expand it unless the device issue returns with a captured trace.
