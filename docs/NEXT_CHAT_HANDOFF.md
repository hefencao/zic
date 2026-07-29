# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.46_single-image-stream-active-run-artifact-prime-runtime-channel.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged. The prior Home delay is not currently reproduced; no eager scan, prewarm or verbose release logging was added.
- Ordinary local static files use one renderer-owned `FileImage` stream. `LocalImagePlayer` does not manually resolve a second stream; actual `Image.frameBuilder` presentation publishes ready. WebP/GIF controlled players retain their separate codec ownership.
- Widget regressions that depend on host codec/file work yield the real event queue without a guessed fixed delay and explicitly unmount codecs/providers. The plain-file routing test verifies zero Dart byte loading and does not conflate that contract with platform decoder completion.
- Promoted page artifact reads start at authoritative `DownloadSession.beginRun`, before ephemeral workspace restore. Page media remains join-only and never creates an independent cache/network demand; immediate snapshot delivery covers late observers.
- Mihon and Venera share protocol v1, one source adapter and now `ExternalPluginRuntimeMessageChannel` plus a versioned handshake. Raw responses are parsed and matched to the request ID; duplicate runtime source identities are rejected; close is joinable.
- Runtime messages contain only protocol-safe primitives, maps/lists and `Uint8List`. Reader, navigation, demand, `DownloadSession`, cache maintenance and artifact objects do not cross the boundary.
- Concrete Mihon class loading and Venera JavaScript execution remain unimplemented and unclaimed.

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

1. Re-run the focused local-image and cold-artifact tests first. If a host codec still fails, capture the first `decodeStarted/frameDecoded/framePresented` sequence rather than adding fixed pump durations.
2. Implement the Android Mihon isolated backend behind `MihonIsolatedRuntimeBackend` and `ExternalPluginRuntimeMessageChannel`: revalidate the exact payload at process entry, load only approved entry classes, distinguish Source/SourceFactory after loading and translate calls to protocol v1.
3. Implement the Venera sandbox backend behind `VeneraSandboxRuntimeBackend` and the same raw channel contract, with approved network/cookie/credential/storage bridges and deterministic teardown.
4. Add protocol conformance fixtures shared by both backends, including malformed handshakes, duplicate source identities, mismatched request IDs, large binary resources, cancellation and close.
5. Keep Home startup telemetry available but do not expand it unless the device issue returns with a captured trace.
