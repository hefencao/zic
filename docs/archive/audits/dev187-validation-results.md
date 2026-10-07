# dev.187 验证结果

## 已执行并通过

- `git diff --check`。
- `python3 -m compileall -q tool`。
- `tool/test_venera_bootstrap.py`：包含 request-scoped 5s delay 被 cancel 后必须在500ms内 reject 的 Node 行为回归。
- dev.157–dev.187 release/ownership gates 全部通过；其中 dev.160/186 仅修正历史 gate 对已经过时具体语法/当前版本文件名的错误固定，不修改生产语义。
- `check_documentation.py`；`check_dart_structure.py`（343 Dart files / 129 test files）；Dart directive-order；Pipeline runtime compile boundary；test quarantine ownership。
- Venera network policy/native binary/response headers/Reader preflight、source-resource atomic binding、Reader streaming、Pipeline demand stability、UI architecture。
- texture schedule timing、Android texture bridge Kotlin compile、frame trace analyzer、vertical geometry/cache/trace、Android runtime dependency/trace-export。
- Mihon entry/payload/ABI/classloader/read-only/chapter contracts、shared browser login bridge、Cloudflare classifier Kotlin compile、external source settings。
- native header check。
- 独立 patch 首轮 replay：在全新 dev.186 完整包副本上 `git apply --check --index` 与 `git apply --index` 均通过；随后 dev.187 gate、Venera bootstrap、documentation、Dart structure、Pipeline compile-boundary均通过，work/replay 1192个文件逐文件SHA-256一致。最终交付 patch 在写回本记录后再次重放确认。

## 完整 check.sh

`bash tool/check.sh`已实际启动，但在第一项 repository check 被 dev.186 唯一基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 阻断；本轮没有从旧ZIC包或临时目录补入该 pinned archive。

## 工具链限制

- Node.js 可用，Venera bootstrap 行为回归已执行。
- 当前环境没有 Flutter/Dart SDK，因此不声称 `flutter analyze`、Dart/Flutter package tests 或 Android App build 已执行。
