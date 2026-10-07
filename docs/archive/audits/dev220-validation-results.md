# dev.220 验证结果

目标版本：`0.31.0-dev.220` / App `0.31.0+220`

## 当前环境可执行结果

- `tool/check_documentation.py`、`tool/test_ui_architecture_contract.py`、`tool/test_reader_streaming_contract.py`、`tool/test_pipeline_demand_stability.py`：通过。后两项已同步到 dev.219/dev.220 的 enqueue-only observation 与 viewport-before-reconcile 边界，不再要求已废弃的同步 `_pipeline.accept` / `_syncViewport` 串联。
- dev.170、174、175、177、183–192、199、205–220 适用 ownership / current-preemption / Venera / partial / physical-transfer / Reader-boundary gates：通过。dev.205/dev.187历史门禁按既有 superseded 语义正常退出。
- dev.206 Kotlin facade stub compile：实际通过（仅未使用参数 warning）。
- `python3 -m py_compile`：dev.218–220 本轮调整/新增 Python gates 通过。

## 本轮新增行为覆盖（源码已实现）

- slider drag 只改变 `_ReaderPageScrubber._previewIndex`；真实 gesture 在 `gesture.up()` 前仍停留原 Reader page，`onChangeEnd` 才提交一次 `ReaderController.requestPage`。旧 callback 测试同步补上 `onChangeEnd`，避免测试继续模拟已废弃的逐 tick commit。
- `ReaderBinding.accept()` 先保存 Reader-local viewport，再执行 demand reconcile；playback projection 在 `finally` 中根据当前 plan 同步。lane reconcile 出错仍可上报，但不能阻止 viewport/presentation fact 前进。
- composition physical trace hub 对 sink 使用引用计数；两个 Reader 共享同一个 App/export sink 时，同一 physical `demandApplied` 对共享 sink 每个 consumer scope只投影一次，同时每个 Reader 的 memory trace 仍保留自己的 physical projection。

当前环境无 Dart/Flutter SDK，因此不得声称上述 Dart/Flutter behavior tests、`flutter analyze` 或 APK build 已实际通过。

## 完整仓库检查限制

`TERM=xterm bash tool/check.sh` 仍在唯一 dev.219 基线缺失的 `third_party/source_archives/libwebp-1.6.0.zip` presence gate 处停止。该 archive 未从旧版本、独立参考包或历史工作目录补入；因此此处记录为既有基线限制，不把后续 Flutter/Rust 阶段记为通过。
