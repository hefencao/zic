# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.56_mihon-payload-context-venera-capability-dns.zip`.
Do not merge or copy files from an earlier zic archive. The 13 files supplied in `git_latest_two_commits.zip` are already incorporated into this baseline.

## Current ownership and completed work

- Keep the existing `home-startup` trace, Reader demand/artifact ownership, resource cache, download sessions and catalog/domain mapping unchanged.
- Mihon/Venera share protocol v1, immutable process-private payload staging, process/session generation, cooperative cancellation and the non-exported `:zic_plugin_runtime` Service. Kotlin drivers adapt ecosystem APIs only; Dart remains the activation/session/limit owner.
- Generated Android hosts own canonical JitPack repository configuration. `extensions-lib` remains non-transitive ABI-only; do not restore a second AndroidX Preference provider or legacy Kohesive Injekt, disable duplicate-class verification, or remove consumer R8 rules.
- Device-installed Mihon extensions are discoverable and copied into the same immutable trust/install path as repository APKs.
- Mihon activation revalidates the copied APK package and host ABI, then uses a payload-specific Context for package name, resources/assets, class loader, theme, LayoutInflater, isolated preferences and file/cache roots. Entry creation supports Kotlin object, static `create/newInstance/getInstance`, `Context` constructor and no-arg constructor. Preserve named entry/root-cause diagnostics.
- Venera activation recognizes direct/array/object/Map explore loaders and current `itemType/categories/categoryParams` plus legacy category targets. `optionLoader` and `optionList` must remain normalized before calling `categoryComics.load`.
- Venera HTTP rewrites source `Accept-Encoding` to gzip/deflate and bounded-decodes the response. When a public hostname resolves only to loopback/private addresses or fails resolution, a bounded DoH fallback may provide only safe numeric A/AAAA addresses to OkHttp custom DNS; URL hostname and TLS verification remain unchanged.
- Do not silently return an empty source list for an unsupported source contract. Fail with a specific capability, entry class or network cause.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/check_android_runtime_dependencies.py
python3 tool/test_android_runtime_dependencies.py
python3 tool/test_configure_platforms.py
python3 tool/test_venera_network_policy.py
python3 tool/test_mihon_entry_instantiation.py
python3 tool/test_mihon_payload_context.py
python3 tool/test_venera_bootstrap.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
flutter pub get
(cd packages/plugin_host && dart test test/plugin_contract_test.dart test/runtime_activation_test.dart test/runtime_service_test.dart test/runtime_worker_test.dart test/runtime_executors_test.dart)
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

1. On an Android device, activate one repository-installed and one device-installed current Keiyoushi 1.6 extension. Record the full named activation cause if either fails; do not generalize it back to `activationFailed`.
2. Exercise official Venera JM browse/detail/chapter/resource on a network where its domain previously resolved to `127.0.0.1`; verify DoH answers remain public and TLS still validates the original hostname.
3. Add instrumentation for plugin install, process kill, explicit reactivation, payload Context resource lookup and WebView teardown.
4. Capture any incompatible real APK/source as a bounded fixture before expanding the adapter. Keep source-specific behavior out of Presentation and do not change tests to conceal product failures.
