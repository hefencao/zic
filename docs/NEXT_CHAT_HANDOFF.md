# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.45_versioned-runtime-protocol-source-adapter.zip`.
Do not merge or copy files from an earlier zic archive.

## Current ownership and completed work

- Keep the existing `home-startup` trace unchanged. The prior Home delay is not currently reproduced; no eager scan, prewarm or verbose release logging was added.
- File-backed cover/local-image and authoritative promoted-artifact ownership from dev.44 remain unchanged.
- `ExternalPluginRuntimeLimits` is const-capable; duration positivity is validated at activation because `Duration` relational operators are not const expressions on the supported Dart SDK range.
- Mihon and Venera executors receive the exact inspected immutable payload and activate an `ExternalPluginRuntimeConnection`.
- The shared protocol is schema version 1 and exposes only source discovery, browse, comic detail, chapter manifest and binary resource operations. Reader, navigation, demand, `DownloadSession`, cache maintenance and artifact APIs do not cross it.
- `ExternalPluginRuntimeSession` adapts runtime descriptors to ordinary `mihon:`/`venera:` `BrowsableComicSource` identities and validates request IDs, response shape, source/comic/chapter/page identity and bounded response size.
- Host timeout and concurrency limits are independent of backend promises. A timeout does not release a permit until the underlying backend call actually exits; queued permits are transferred FIFO without overcommit.
- Session close is joinable, rejects queued calls, signals the isolated connection before draining actual work and closes invalid runtime handshakes.
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
cd packages/plugin_host && dart test
cd ../plugin_host_bridge && flutter test
cd ../../
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Implement the Android Mihon isolated backend behind `MihonIsolatedRuntimeBackend`: revalidate the exact payload hash, signer, package, version and ABI at process entry; load only normalized approved entry classes; identify Source versus SourceFactory after loading; translate extension calls to protocol version 1; and deterministically terminate the dedicated process/session.
2. Implement the Venera backend behind `VeneraSandboxRuntimeBackend`: evaluate only the inspected script in a bounded engine; expose network/cookie/credential/storage through approved bridges; translate source calls to protocol version 1; and enforce timeout, heap, concurrency, response and teardown limits.
3. Add protocol conformance fixtures shared by the future Mihon and Venera backends, including malformed wire payloads, cancellation/close, large binary resources and multi-source handshakes.
4. Keep Home startup telemetry available but do not expand it unless the device issue returns with a captured trace.
