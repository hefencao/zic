# dev.192 验证结果

## 结论

本轮仅增加 rhttp 持续传输分段观测，不修改 network=5、NetLane admission/preemption、Reader 7/3、DownloadJob 16/64KiB 单一聚合，也不增加 bandwidth scheduler。`ByteResponseReadDiagnostics` 只有 `snapshot()`；逐事件 rhttp progress/body instrumentation 只在 non-product 构建启用，product/release 不注册额外 progress callback。

## 已执行并通过

- `git diff --check`
- `python3 -m compileall -q tool`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- `python3 tool/test_frame_pipeline_trace_analyzer.py`
- `python3 tool/test_dev178_vibevenera_rhttp_startup_transport.py`
- `python3 tool/test_dev179_toolchain_rhttp_chunk_owner.py` 至 `tool/test_dev192_rhttp_transfer_stage_observation.py` 的相关连续 release/ownership gates
- `python3 tool/test_source_resource_binding.py`
- `python3 tool/test_reader_streaming_contract.py`
- `python3 tool/test_pipeline_demand_stability.py`
- `python3 tool/test_ui_architecture_contract.py`
- Venera network policy / native binary / Reader preflight / response headers / source-requested network cache / Node bootstrap contracts
- Mihon entry / payload / ABI / classloader / read-only payload / chapter contracts
- shared external login bridge / external source settings contracts
- Cloudflare classifier Kotlin compile/behavior contract
- texture schedule timing / Android texture bridge Kotlin compile contracts
- Android runtime dependency / trace-export contracts
- vertical geometry / artwork cache / trace contract
- `bash tool/check_native_header.sh`
- 使用 dev.191 真机 trace 执行 `tool/analyze_frame_pipeline_trace.py --json` 成功；旧 trace 缺少 dev.192 新字段时按空/零统计兼容解析，不制造虚假观测。

Kotlin 独立编译测试仅出现 stub 未使用参数 warning，没有 Kotlin compile failure。批量执行超过单次命令窗口的 Kotlin 测试已拆开单独重跑并通过，未把 timeout 当作产品通过或失败。

## 完整检查的已知阻断

实际执行 `bash tool/check.sh`，在第一项因 dev.191 基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 退出。没有从旧版本或其它工作目录补入该 archive，因此不能声称完整 `tool/check.sh` 通过。

当前执行环境存在 Node，但没有 Dart/Flutter SDK；因此本轮没有声称运行 `dart analyze`、Dart/Flutter tests 或完整 Flutter/Android App build。

## Patch replay

初版 patch replay 首次暴露了一个交付问题：新 ADR、两份 audit 与 dev.192 gate 仍是 untracked，普通 `git diff` 不会自动纳入。已用 intent-to-add 将这些新文件纳入最终 diff，并重新生成 patch；没有把这次失败记成通过。

修正后的候选 patch 在通过 `unzip` 保留 Unix mode 的原始 dev.191 ZIP fresh extract 上：

- `.zic-workspace.json` 应用前不存在；
- `git apply --check --index` 通过；
- `git apply --index` 通过；
- `.zic-workspace.json` 应用后仍不存在；
- replay 中 dev.192 ownership gate、documentation、Dart structure 与 frame-trace analyzer gate 通过；
- 工作树与 replay 共 1213 个有效文件，missing=0、extra=0、content/executable-mode difference=0。

最终审计文本写入后已重新生成最终 patch，并在第二个原始 dev.191 fresh extract 上再次执行 `git apply --check --index` 与 `git apply --index`；两者通过，工作树与 final replay 仍为 1213 / 1213 个有效文件，missing=0、extra=0、content/executable-mode difference=0。
