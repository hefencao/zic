# dev.164 验证结果

## 已执行

- `python3 tool/check_dart_structure.py`：通过，341 Dart files / 129 test files；新增 Home projection race test 的结构也通过解析。
- `python3 -m py_compile tool/*.py`、`bash -n tool/check.sh`：通过。
- dev.75–dev.164 Python ownership/contract gates：除 dev.98 外全部通过；dev.98 依赖当前唯一基线缺失的 pinned libwebp archive，按既有规则未从旧包补入。
- `tool/test_pipeline_runtime_compile_boundary.py`、`tool/test_source_resource_binding.py`、`tool/test_reader_streaming_contract.py`、`tool/test_ui_architecture_contract.py`：通过。
- 修改 projection revision 后重新执行 dev.137、139、143、145、156、157、160–164，以及 source-resource、Reader streaming、UI architecture、Venera bootstrap/preflight、Mihon chapter contract：全部通过。
- Mihon/Venera/network 相关合同：payload context、ABI routing、classloader、read-only payload、chapter contract、Venera response headers/reader preflight/bootstrap、external settings/login、Cloudflare classifier等均通过。
- Android texture bridge Kotlin stub compile：通过。
- dev.164 `RuntimeServiceRequestLifecyclePolicy.kt` 直接 `kotlinc` 编译：通过。
- dev.164 `PluginRuntimeServiceClient.kt` + `RuntimeServiceRequestLifecyclePolicy.kt` 使用最小 Android/Flutter/runtime stub执行 `kotlinc` 编译：通过；用于验证本轮 Kotlin语法与 client/policy类型边界。
- `python3 tool/check_repo.py`：执行后仅在当前唯一基线既有缺件 `third_party/source_archives/libwebp-1.6.0.zip` 处停止；未从旧项目包补文件。
- 从全新 dev.163 基线生成 Patch 后执行 `git apply --check --index` 与 `git apply --index`：通过；回放树与工作树 1095 个发行文件逐文件内容及 executable bit一致。回放预检曾发现第一次 patch生成未包含6个 untracked新增文件，因此该候选已废弃并改用 staged index生成，最终 patch包含31个变更/新增文件。
- 完整 ZIP 执行 `unzip -t`：通过；独立解压后重新执行 Dart structure、dev.139、dev.164、source-resource binding、UI architecture、Venera bootstrap：全部通过。

## 未执行

当前环境没有 Flutter/Dart SDK，因此未执行：

- `flutter analyze`
- Flutter/Dart package tests，包括新增 `home_library_session_test` 与 `method_channel_runtime_backends_test`
- Android debug/release APK build与真机测试

当前环境也没有完整 Android SDK/NDK，因此 stub Kotlin compile不能替代真实 Android Gradle build。

## 结论等级

- Home projection / stale-reload rejection / artwork revision / runtime generation ownership：`Verified-static`
- Kotlin policy/client编译边界：`Verified-toolchain(stub)`
- Flutter/API完整编译：`Unverified`
- 真机行为：`Unverified`
