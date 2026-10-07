# dev.197 验证结果

## 变更范围

- App Debug Trace export projection：`framePipelineTiming` / `decodeRefill` 语义分桶合并。
- 新增流式 `tool/filter_debug_trace.py` 与独立工具测试。
- 新增 dev.197 静态 gate、ADR 与审计文档。
- 不改变下载、Range/resume、播放、Reader/Pipeline、NetLane 或 Venera/Mihon 运行策略。

## 已执行验证

通过：

- `python3 tool/test_debug_trace_filter.py`
- `python3 tool/test_dev197_trace_export_compaction.py`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.170–189 连续 release/ownership gates；dev.190–192、dev.195–197 相关 gates
- source-resource atomic binding、Reader streaming/output、Pipeline demand stability、UI architecture
- Android trace export、frame pipeline trace analyzer
- Venera network policy、response header、Reader preflight、bootstrap、native binary
- Mihon entry、payload Context、ABI routing、classloader、read-only payload、chapter contract
- Cloudflare typed classifier Kotlin compile/behavior
- Android texture bridge Kotlin compile、texture schedule timing contract
- `python3 -m compileall -q tool`
- candidate release repo `git diff --check`

`test_texture_bridge_kotlin_compile.py` 首次批跑超过单次 120 秒窗口；随后作为独立项重跑并通过。该 timeout 未被记作产品失败或通过。

当前环境没有 Dart/Flutter SDK，因此没有执行并不得声称通过 `dart analyze`、Dart/Flutter tests 或完整 Android Flutter build。环境存在 Kotlin/Java，可执行的独立 Kotlin contracts 已按上面记录运行。

完整 `bash tool/check.sh` 实际执行，退出于权威基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 前置检查；未从旧版本补入该 archive。

## Trace 工具实测

对 `zic-debug-trace-2026-08-10T05-28-25.jsonl` 逐行过滤：

- 原始：5502 个 JSON 对象，1,792,434 bytes；
- network：1627 条，476,776 bytes；
- playback：3479 条，1,210,067 bytes；
- failures：69 条，16,904 bytes。

这些只是离线诊断视图；原始 trace 没有被修改。按 dev.197 语义键/时间窗对现有 trace 的离线模拟中，`framePipelineTiming` 177 条约收敛到 54 个桶，`decodeRefill` 433 条约收敛到 189 个桶；未来真机文件大小仍取决于实际操作和其它事件，不能把该模拟视为固定压缩率。

## Authoritative patch replay

最终审计文本冻结前的 candidate patch 已从原始 dev.196 完整 ZIP fresh extract 初始化 Git baseline 并实际执行：

- `git apply --check --index`：PASS
- `git apply --index`：PASS
- work：1227 files
- replay：1227 files
- missing：0
- extra：0
- content / executable-mode diff：0

预最终 patch 在审计结果写回后再次 fresh replay，仍为 1227 / 1227、missing=0、extra=0、content/executable-mode diff=0。完整项目 provisional ZIP 解压比对同样为 1227 / 1227、missing=0、extra=0、content/executable-mode diff=0，且不含 `.git` / `.zic-workspace.json`。随后将本验证文本冻结并重新生成 release patch；冻结文本版本的 lock-check fresh replay 再次得到 1227 / 1227、missing=0、extra=0、content/executable-mode diff=0。最终交付的接受条件固定为：patch 与 ZIP 必须由同一冻结工作树生成，并在原始 dev.196 fresh extract / ZIP fresh extract 上分别达到 1227 / 1227、missing=0、extra=0、content/executable-mode diff=0；任一条件不满足则不得交付。
