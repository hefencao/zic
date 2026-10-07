# dev.230 validation results

## 当前环境

- Dart SDK：不可用。
- Flutter SDK：不可用。
- Kotlin compiler：可用；dev.206 Kotlin facade stub 已实际编译通过（仅参数未使用 warning）。
- 基线继续缺少`third_party/source_archives/libwebp-1.6.0.zip`，不得从旧版本补入。

## 已执行

- `python3 tool/check_documentation.py`：通过。
- `python3 tool/check_dart_structure.py`：通过（352 Dart files / 131 test files）。
- `python3 tool/check_test_quarantine.py`：通过。
- `python3 tool/test_dev230_remove_hard_artifact_alias.py`：通过。
- dev.107 / 109 / 135 / 208 / 211 / 229 历史owner契约已按dev.230 owner迁移重新验证：通过。
- dev.205–230 ownership/version/partial链并行回归：全部通过；其中dev.206 Kotlin facade stub实际编译通过。
- `test_pipeline_runtime_compile_boundary.py`、`test_pipeline_demand_stability.py`、`test_reader_streaming_contract.py`、`test_ui_architecture_contract.py`：通过。
- production/current stable docs仓库级引用审计：不存在`resolveAlias`、hard artifact `alias/rekey`、`applyExisting/rekeyExisting`或`aliasMaxEntries`残留调用；exact durable ownership继续使用`containsBackendExact`。
- `bash tool/check.sh`：在第一项基线前置条件处停止，仅报告缺失pinned `third_party/source_archives/libwebp-1.6.0.zip`；未发现新的项目gate失败。

## 未验证

- dev.230新增Dart行为测试实际执行；
- `flutter analyze` / Flutter tests / Android APK；
- 真机`skip-verified-equivalent-durable`与显式exact completion。

## 发行重放

- 预最终ordinary Patch已从pristine dev.229执行`git apply --check --index` / `git apply --index`：通过；与候选树比较`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。
- 预最终完整ZIP独立解压比较：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`，禁止发行项`banned=0`。
- 预最终Exact Patch Replay v1已在第三份pristine dev.229上自测：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。
- 本validation写入上述真实结果后，最终Patch/完整ZIP/Exact Replay已再次冻结并执行同样三路比较：ordinary Patch、完整ZIP、Exact Replay均`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`，完整ZIP`banned=0`。
