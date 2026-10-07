# dev.173 验证结果

## 环境

- 当前发行版本：Source `0.31.0-dev.173`，App `0.31.0+173`，Android `versionCode=173`。
- 当前环境有 `kotlinc`，无 Dart/Flutter SDK；因此 Flutter widget tests、`flutter analyze` 与 APK build 本轮未执行，不能标记为通过。
- `check_repo.py` 仍只在 dev.172 基线已有的 `third_party/source_archives/libwebp-1.6.0.zip` 缺失处停止；没有从旧 ZIP 回填。

## 已执行

- `python3 tool/check_dart_structure.py`：341 个 Dart 文件、129 个测试文件，OK。
- `python3 tool/test_dev139_current_documentation.py`：OK；`ARCHITECTURE.md` 420 行，`NEXT_CHAT_HANDOFF.md` 80 行。
- `python3 -m py_compile tool/*.py`、`bash -n tool/check.sh`：OK。
- dev.135–147、dev.148–160、dev.161–170、dev.171–173 受影响 ownership gates 均得到明确 PASS；批处理累计 Kotlin 编译超过单次执行窗口时从断点继续，没有把超时当通过。
- source-resource atomic binding、UI architecture、Venera bootstrap/Reader preflight/network policy、Mihon entry/payload Context/ABI/classloader/chapter、external source settings、Reader streaming 与 Pipeline demand contracts：PASS。Mihon相关 Kotlin compile测试实际使用 `kotlinc`。
- dev.173 新 gate检查：左上书架/右上更新提示分离、Home `sourceUpdateAt`投影、通用迁移入口、同源确认关系直接查看、跨源候选搜索、统一严格比较、same-source旧 raw preference中和。

## Patch 回放

从原始 `zic_v0.31.0-dev.172_runtime-browse-protocol-contract.zip` 全新解压建立 Git baseline。候选 diff 审查发现工作目录中 dev.170/dev.171/dev.172 Python gate存在与产品无关的 executable-bit污染；这些 mode change 已全部按 dev.172基线恢复，没有进入正式 Patch。

冻结 validation 后重新生成正式 dev.172→dev.173 Patch，并真实执行：

- `git diff --cached --check`
- `git apply --check --index`
- `git apply --index`

最终回放：

- 工作树发行文件：1133
- 回放树发行文件：1133
- missing：0
- extra：0
- content diff：0
- executable-bit diff：0
- 正式 Patch实际修改/新增文件：24
