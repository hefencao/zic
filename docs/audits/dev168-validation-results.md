# dev.168 验证结果

## 已执行

- `tool/test_dev75_*.py` 至 `tool/test_dev168_*.py`：除 dev.98 外共 92 个历史/当前 Python ownership gates 全部通过；dev.145 gate已迁移为“目标精确请求 cache + 禁止最近 projection反向恢复 UI默认状态”，没有恢复旧 fallback。
- `python3 tool/check_dart_structure.py`：通过，341 个 Dart 文件、129 个 test 文件。
- `python3 tool/test_dart_library_directive_order.py`：通过。
- `python3 tool/check_documentation.py`、`python3 tool/test_dev139_current_documentation.py`：通过；`ARCHITECTURE.md` 418 行，`NEXT_CHAT_HANDOFF.md` 76 行。
- `python3 tool/test_ui_architecture_contract.py`、`python3 tool/test_venera_bootstrap.py`、`bash tool/check_native_header.sh`：通过。
- `python3 tool/test_dev154_network_browser_activity_kotlin_compile.py`：通过；只有测试 stub 未使用参数 warning。
- `python3 -m py_compile tool/*.py` 与全部 `tool/*.sh` 的 `bash -n`：通过。

## 新增回归合同

- `apps/app/test/source_browser_test.dart`：新增“filter capability 存在但 schema为空时，分类栏仍显示筛选入口并能打开明确空状态”的 widget contract。
- 同一 widget contract 增加首次 section 断言：当前展示顺序为“最新 → 热门”时，首次选中必须是“最新”，并且实际 browse request 也进入 `latest`。
- `packages/plugin_host/test/runtime_source_adapter_test.dart`：增加 Mihon `supportsSearchFilters=true`、Venera `false` 的 runtime capability contract。
- `tool/test_dev168_source_filter_default_owner.py`：禁止 source browser重新消费 `peekLatestBrowseProjection()`作为 UI默认状态，并锁定 capability/schema 分离与单一 section排序/default owner。

## 当前环境限制

- 当前环境没有 `flutter` / `dart` 可执行文件，因此未实际运行 Flutter analyzer、widget tests或 Dart package tests；上述新增 Dart tests只能作为待本地工具链验证项，不能标记为已执行通过。
- `python3 tool/check_repo.py` 仍只在唯一 dev.167 基线已缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 处停止；本轮没有从旧版本补入该 archive，也没有运行依赖它的 dev.98 source build gate。
- Android APK/debug/release 真机构建未在当前环境执行。
