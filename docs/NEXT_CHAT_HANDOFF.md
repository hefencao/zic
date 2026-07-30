# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.58_mihon-versioned-abi-venera-runtime-semantics.zip`.
Do not merge or copy files from an earlier zic archive. The files previously supplied in `git_latest_two_commits.zip` remain incorporated.

## Current ownership and completed work

- Preserve Home startup, Reader demand/artifact ownership, resource cache, download sessions and catalog/domain mapping. External plugins remain ordinary `BrowsableComicSource` adapters in the dedicated `:zic_plugin_runtime` process.
- Mihon repository/device APKs share the immutable trust path, payload-specific Context and named entry diagnostics. Source API classes are now versioned child-first dex assets; only common runtime libraries remain a single parent provider.
- Android 14+ dynamic code loading requires both the runtime APK and selected Mihon ABI jar to be non-writable. Keep `stageReadOnlyMihonCode`: open a same-directory `.part`, mark the path read-only before writing through the already-open descriptor, fsync, verify length/SHA-256, rename, reassert read-only state, and verify before `DexClassLoader`.
- Venera loader discovery must accept both `load` and cursor-style `loadNext`. Cursor state is runtime-local and keyed by operation/query/options; page one resets it. Preserve `{comics,next}` and ordinary page-number contracts.
- Venera catalog/detail covers are absolute HTTP(S) URIs and must be readable through `loadResource`; only chapter-page transformations require `venera-resource://` tokens. Both paths stay inside the approved network/cookie/response/image bridge.
- Runtime output uses `vertical`, but the Dart protocol adapter intentionally accepts legacy `topToBottom`, `webtoon`, `leftToRight` and `rightToLeft` aliases. Unknown values remain errors.
- Venera static source-key inspection is non-executing and class-scoped. It must not scan method-local `key` variables or weaken repository/script mismatch checks.
- Response headers cross two Android shapes: nullable `HttpURLConnection.headerFields` and non-null OkHttp multimap. Keep the `Map<*, *>` normalizer and do not reintroduce an invariant generic signature.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/check_android_runtime_dependencies.py
python3 tool/test_android_runtime_dependencies.py
python3 tool/test_configure_platforms.py
python3 tool/test_venera_network_policy.py
python3 tool/test_venera_bootstrap.py
python3 tool/test_venera_response_headers.py
python3 tool/test_mihon_entry_instantiation.py
python3 tool/test_mihon_payload_context.py
python3 tool/test_mihon_abi_routing.py
python3 tool/test_mihon_classloader_contract.py
python3 tool/test_mihon_read_only_payload.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
flutter pub get
(cd packages/plugin_host && dart test test/payload_inspectors_test.dart test/runtime_source_adapter_test.dart test/plugin_contract_test.dart test/runtime_activation_test.dart test/runtime_service_test.dart test/runtime_worker_test.dart test/runtime_executors_test.dart)
(cd packages/plugin_host_bridge && flutter test test/android_mihon_metadata_reader_test.dart test/external_plugin_controller_manifest_test.dart test/method_channel_runtime_backends_test.dart test/runtime_service_handler_test.dart test/runtime_service_entrypoint_test.dart)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest --tests dev.zic.pluginhost.MihonHostAbiTest --tests dev.zic.pluginhost.MihonRuntimeWorkspaceTest --tests dev.zic.pluginhost.VeneraNetworkPolicyTest --tests dev.zic.pluginhost.VeneraResponseDecodingTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Build and activate the reported `eu.kanade.tachiyomi.extension.all.ehentai` 1.4 APK on Android 14+; confirm the selected `mihon/abi/1.4/abi.jar` and staged APK are non-writable, and capture any subsequent named entry/root cause.
2. Exercise official Venera e-hentai and Picacg install, activation, first/second browse pages, cover fetch, detail, chapter and page resource paths. Record the exact source result shape before adding any new normalization.
3. Add Android instrumentation around process kill/reactivation and WebView teardown without moving session or cache ownership into Kotlin.
4. Keep source-specific UI branches out of Presentation and never change tests to conceal a product failure.


## dev.58 runtime invariants

- `mihonAbi14` and `mihonAbi16` are build-time-only. Never put either `extensions-lib` on the App runtime classpath.
- `generateMihonAbiAssets` must run before Android `preBuild`; verify both generated assets are packaged under `assets/mihon/abi/` and activation selects by `extensionLib`.
- Preserve child-first loading only for Tachiyomi/extension namespaces; AndroidX Preference and the remaining common runtime stay parent-first.
- Venera default invocation timeout is 55 seconds and the legacy global `res` compatibility binding is intentional.
