# dev.186 验证结果

## 已执行

- `python3 tool/check_documentation.py`：通过。
- `python3 tool/check_dart_structure.py`：通过（343 Dart files / 129 test files）。
- `python3 tool/test_dart_library_directive_order.py`：通过。
- `python3 tool/test_pipeline_runtime_compile_boundary.py`：通过。
- dev.157–dev.185 近期 ownership/release gates：通过；dev.175/177/181/183/184/185 与本轮 Venera/source/Reader 改动直接相关的 gate 均通过。
- `tool/test_venera_network_policy.py`、`tool/test_venera_reader_preflight.py`、`tool/test_source_resource_binding.py`、`tool/test_reader_streaming_contract.py`、`tool/test_ui_architecture_contract.py`、`tool/test_mihon_chapter_contract.py`：通过。
- `python3 tool/test_venera_bootstrap.py`：通过（Node.js 可用）。
- `bash tool/check_native_header.sh`：通过。
- `git diff --check`：通过。
- `tool/test_dev186_venera_previous_pressure_source_open_stages.py`：通过。

## 环境限制

当前环境没有 Dart/Flutter SDK，因此不能实际执行 `dart test`、`flutter test`、analyzer 或 Android Flutter build；新增的 runtime gate/source diagnostics Dart tests 作为源码回归交付，不能记为本环境已运行通过。

完整 `tool/check.sh` 的第一项 `check_repo.py` 仍被 dev.185 基线继承的 pinned libwebp archive 缺失阻断：`third_party/source_archives/libwebp-1.6.0.zip` 不存在。本轮没有从旧包或其它基线偷补该归档。

## 需要真机验证

1. previous 660→780 到外层 `downloadStarted` 继续保持毫秒级，不出现 dev.184/185 前的秒级 admission 等待。
2. Venera nested gate：780 相对 active request-plan 差值>=40时可发 requestId cancellation，但新 invocation只在旧 JavaScript `finished(requestId)` 后开始，单上下文无物理重叠。
3. 对慢 origin 比较 `sourceRequestPlanMicros` 与 `sourceHostOpenMicros`；若前者主导，再优化 request-plan/runtime；若后者主导，再追 rhttp/DNS/TLS/首包。不要重新修改7/3、5路并发、780/1000或transport framing。
