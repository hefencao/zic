# dev.198 验证结果

## 变更范围

- rhttp direct transport：product/release 默认输出 HTTP version、匿名 remote-IP hash 和 progress-enabled 标记；高频 receive-progress 默认关闭。
- `tool/build_android.sh`：增加显式 `ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=1` 诊断构建开关；普通 release 构建行为不变。
- trace analyzer：增加匿名 endpoint hash 与 receive-progress enabled 计数；旧 trace 缺少字段时保持兼容。
- 新增 dev.198 gate、ADR 与根因审计。
- 不改变下载、Range/resume、playback、Reader/Pipeline、NetLane 或 rhttp framing 策略。

## 已执行并通过

### 基础与文档

- `bash -n tool/build_android.sh`
- `python3 -m compileall -q tool`
- `python3 tool/test_dev198_product_safe_rhttp_endpoint_diagnostics.py`
- `python3 tool/test_dev192_rhttp_transfer_stage_observation.py`
- `python3 tool/test_dev197_trace_export_compaction.py`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 个 Dart 文件 / 129 个测试文件
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- `python3 tool/test_android_trace_export_contract.py`
- `python3 tool/test_frame_pipeline_trace_analyzer.py`
- `git diff --check`

### 连续 release / ownership gates

- dev.175–dev.192 相关 gate 全部通过。
- dev.195、dev.196、dev.197、dev.198 gate 全部通过。

### Source / Reader / Pipeline / Plugin / Android 合同

- source-resource binding 与 dev.162 atomic/catalog boundary 通过。
- Reader streaming/output、Pipeline demand stability、UI architecture 通过。
- Venera Network cache、network policy、response headers、Reader preflight、bootstrap、native binary 合同通过。
- Mihon entry、payload Context、ABI routing、classloader、read-only payload、chapter contract 通过。
- Cloudflare typed classifier Kotlin 合同通过。
- texture schedule timing、Android texture bridge Kotlin compile、Android runtime dependency 合同通过。

批量平台测试曾在 Mihon ABI Kotlin 编译段达到单次执行窗口；相关项目随后拆开单独执行并通过，因此没有把 timeout 计作通过或失败。

## Trace / 工具兼容验证

- `tool/filter_debug_trace.py` 对 `zic-debug-trace-2026-08-10T06-36-06.jsonl` 的 `network` profile 实际过滤为 841 / 3287 个事件，输出约 279276 bytes。
- 新 analyzer 可读取该旧 trace；由于 dev.197 trace 尚无 dev.198 endpoint/progress-enabled 字段，相应计数为空而非报错。
- `ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS` 非 `0|1` 时 `tool/build_android.sh` 返回 64，并拒绝继续构建。

## 完整检查的继承缺口

实际执行 `bash tool/check.sh`，仍在权威 dev.197 基线继承缺失的：

`third_party/source_archives/libwebp-1.6.0.zip`

前置检查处退出（exit 1）。没有从旧版本或其它候选包补入该文件。

## 当前环境未执行

当前环境没有 `dart` / `flutter` 可执行文件，因此没有声称执行通过：

- `dart analyze`
- Dart package tests
- Flutter tests
- 完整 Flutter Android build

## Replay / package 验证

从原始 dev.197 完整 ZIP fresh extract 已完成两轮实际校验。

第一次 candidate replay：

- `git apply --check --index`：PASS
- `git apply --index`：PASS
- 冻结工作树：1231 files
- replay：1231 files
- missing：0
- extra：0
- content / executable-mode different：0

在写入第一次 replay 结果并重新生成 patch 后，pre-final replay 与 package fresh-extract 比较：

- replay：1231 / 1231，missing=0，extra=0，content/mode different=0
- package：1231 / 1231，missing=0，extra=0，content/mode different=0
- 最终包禁入项检查：`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc` 均为 0

用于 `git apply --index` 的 replay 临时工作目录自身会初始化 `.git`，该目录不是交付包，因此只对最终 ZIP 执行 `.git` 禁入检查。

本节写入后必须重新生成 canonical dev.197→dev.198 patch，并再从原始 dev.197 fresh extract 执行最终 replay；最终完整 ZIP也必须从同一冻结树重新生成并 fresh extract 比对。写入本节后不再修改源码或文档。
