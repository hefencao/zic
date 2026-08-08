# dev.172 验证结果

## 环境与基线

- 唯一代码基线：`zic_v0.31.0-dev.171_filter-shelf-download-feedback.zip`。
- 当前发行版本：Source `0.31.0-dev.172`，Android `versionCode=172`。
- 输入设备证据：`错误报告(20260808-142635).txt`、`zic-debug-trace-2026-08-08T14-27-09.jsonl`。
- 当前环境有 Python、Git、Kotlin/JVM、Node；没有 Dart/Flutter SDK和完整 Android SDK/NDK，因此不宣称 `flutter analyze`、Flutter/Dart tests或 APK build已执行通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py`仅在该既有缺件处停止，未从旧包补入。

## Trace / 错误报告验证

- trace共32条事件。`external-plugin-host`已 ready 后，`venera:ehentai` 普通 browse以 `filterViewActive=false/filterCount=0`启动，约242微秒后以 `FormatException`失败。
- Mihon 18comic普通 latest browse约897微秒后以同一 `FormatException`失败，强制刷新约795微秒后同样失败；roumanwu普通 latest browse约470微秒后同样失败。
- 错误报告栈明确位于 `runtime_protocol.dart::_expectKeys/_validateArguments` → `ExternalPluginRuntimeRequest` → `_RuntimeBrowsableComicSource._browse`，发生在 runtime/plugin调用前。
- 源码对照确认 dev.171 adapter始终发送 `useFilters`，Mihon driver读取 `useFilters`，但 browse validator仍只允许旧 key集合，因此 Venera/Mihon共享 wire contract一起失效。

## 实现验证

- `ExternalPluginRuntimeRequest.browse` typed factory新增 `useFilters=false`并显式序列化。
- browse validator把 `useFilters`作为 schema v1唯一明确 optional additive字段；存在时必须为 bool，未知字段继续拒绝。
- runtime protocol test新增：filter-mode round-trip、旧 v1缺省 `useFilters`兼容、非法类型与未知字段拒绝。
- `tool/check.sh`补接 dev.171 gate并加入 dev.172 runtime browse protocol gate；无 Dart SDK时仍验证 protocol/factory/adapter/Mihon driver四端。

## 静态与工具链验证

已通过：

- `check_dart_structure.py`：341 Dart files / 129 test files。
- `test_dart_library_directive_order.py`、`check_documentation.py`、`test_dev139_current_documentation.py`。
- 97个 `test_dev*.py` 中96个通过；dev.98仅因当前基线缺 pinned libwebp archive排除。
- dev.171与dev.172 owner/protocol gates。
- Mihon payload Context Kotlin编译、ABI routing、split classloader、chapter contract。
- Venera bootstrap、Reader preflight、network policy、native binary与response headers。
- source-resource atomic binding、UI architecture、Reader streaming/demand、texture Kotlin compile、Android runtime dependency、Cloudflare classifier、external login/settings。
- `python3 -m py_compile tool/*.py`、`bash -n tool/check.sh`；`check_native_header.sh`通过 `bash`调用执行，未改变 baseline脚本 executable bit。

## Repository check

`python3 tool/check_repo.py`只停止于：

`third_party/source_archives/libwebp-1.6.0.zip` 缺失。

这是 dev.171基线既有缺件，本轮未从旧 ZIP补入。

## Patch 预回放

写入本文件前，从全新 dev.171项目根目录生成预 Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

工作树与回放树均为1128个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0；预 Patch含15个实际修改/新增文件。

加入本 validation文件后的候选回放包含1129个发行文件、16个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成最终 Patch并从全新 dev.171再次执行 `git apply --check --index` / `git apply --index` 与完整 manifest/mode比较。最终发行只有在冻结后的结果仍为1129 / 0 / 0 / 0 / 0时成立。
