# dev.171 验证结果

## 环境与基线

- 唯一代码基线：`zic_v0.31.0-dev.170_mihon-cleartext-media-retry-owner.zip`。
- 当前发行版本：Source `0.31.0-dev.171`，Android `versionCode=171`。
- 当前环境有 Python、Git、Kotlin/JVM 编译工具；没有 Dart/Flutter SDK，因此不宣称 `flutter analyze`、Flutter/Dart tests 或 APK build 已执行通过。
- 基线仍缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py` 仅在该既有缺件处停止，未从旧包补入。

## 本轮 trace 证据

对 `zic-debug-trace-2026-08-08T12-41-26.jsonl` 做结构化扫描：

- 共 2225 条事件；`taskFailed=0`，`downloadStarted=27`。
- WNACG source `mihon:6551136894818591762`：`cover-load-start=103`、`cover-source-ready=103`、`cover-first-frame=103`，说明 dev.170 cleartext media 修复在本样本中没有重现旧的封面/正文 cleartext 热循环。
- 筛选应用时 trace 仍记录 `sectionId=latest` 与 `filterCount=1`，说明 dev.170 没有把“筛选视图已激活”建模成独立状态；这与界面焦点仍留在 Latest/Popular 的现象一致。
- Reader 后续可直接从 durable artifact cache 恢复已驻留页；因此 artifact/cache residency 只能表达资源存在，不能作为“用户当前下载命令完成”的 UI 事实。

## 静态与工具链验证

已通过：

- `check_dart_structure.py`：341 Dart files / 129 test files。
- `test_dart_library_directive_order.py`。
- `check_documentation.py`、`test_dev139_current_documentation.py`；`ARCHITECTURE.md=420` 行、`NEXT_CHAT_HANDOFF.md=80` 行。
- dev.75–dev.170 历史 Python ownership gates（dev.98 因基线缺 pinned libwebp archive 排除）。
- dev.171 `test_dev171_filter_shelf_download_feedback.py`。
- Mihon entry/payload/ABI/split-classloader/read-only/chapter contracts；其中 payload 与 Cloudflare browser handoff 含实际 Kotlin 编译。
- `test_source_resource_binding.py`、`test_ui_architecture_contract.py`、`test_venera_reader_preflight.py`、`test_venera_bootstrap.py`、`test_venera_network_policy.py`。
- `test_texture_bridge_kotlin_compile.py`、`check_native_header.sh`。
- `python3 -m py_compile tool/*.py` 与全部 `tool/*.sh` shell syntax。

## Patch 回放

在写入本文件前的预回放从全新 dev.170 项目根目录生成 Patch，并实际执行：

- `git apply --check --index`
- `git apply --index`

预回放比较 1124 个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。预回放同时发现工作树中 dev.170 gate 的 executable bit 被工具过程意外清除；在正式发行冻结前已恢复该基线执行位，不把无关 mode change 纳入正式 Patch。

正式发行冻结前的完整候选回放包含本 validation 文件，共 1125 个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成最终 Patch并从全新 dev.170 再次执行同样回放，最终发行只在结果仍为 1125 / 0 / 0 / 0 / 0 时成立。
