# dev.209 验证结果

## 基线与环境

- 唯一代码基线：`zic_v0.31.0-dev.208_version-relation-projection-bidirectional-artifact-reuse.zip`。
- 当前发行版本：`0.31.0-dev.209` / App `0.31.0+209` / Android `versionCode=209`。
- 用户本地编译错误：`demo_home_source_migration.dart:303` 调用已删除 `_reconcileConfirmedSourceUpdateSignal`。
- 当前环境有 Python、Git、Kotlin/JVM；没有 Dart/Flutter SDK，因此不能声称 `flutter analyze`、Dart/Flutter tests 或 APK build 已执行通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py` 仅在该既有缺件处停止，未从旧版本或独立 libwebp 包补入。

## 根因与修复验证

- `demo_home_source_migration.dart::_loadSourceVersionState()` 确实残留对已删除 `_reconcileConfirmedSourceUpdateSignal` 的调用。
- 该调用已直接删除；没有恢复旧方法，也没有增加 relation → `sourceUpdateAt` 替代写回。
- `apps/` 与 `packages/` 中 `_reconcileConfirmedSourceUpdateSignal` 当前为 0 引用。
- dev.208 gate 已加强为禁止迁移生产文件出现该符号任意引用；新增 dev.209 closure gate并接入 `tool/check.sh`。

## 已执行验证

通过：

- `check_dart_structure.py`：347 Dart files / 130 test files。
- `test_dart_library_directive_order.py`。
- `check_documentation.py`、`test_dev139_current_documentation.py`。
- dev.165、dev.207、dev.208、dev.209 ownership/closure gates。
- `test_source_resource_binding.py`、`test_ui_architecture_contract.py`。
- Venera bootstrap / Reader preflight。
- Mihon payload Context Kotlin compile / ABI routing / chapter contract。
- `python3 -m py_compile tool/*.py` 与全部 `tool/*.sh` shell syntax。

`python3 tool/check_repo.py` 只停止于 dev.208 基线既有 pinned libwebp archive 缺失。

## Patch 回放

加入本 validation 文件后的候选回放已经从全新 dev.208 项目根目录实际执行 `git apply --check --index` / `git apply --index`：12 个真实修改/新增文件、1279 个发行文件，missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式 Patch并第二次从全新 dev.208 回放，最终发行仅在结果仍为 1279 / 0 / 0 / 0 / 0 时成立。
