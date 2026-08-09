# dev.182 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.181_artifact-cache-controlled-origin.zip`。
- 本轮设备证据：`zic-debug-trace-2026-08-09T05-38-39.jsonl`。
- 只读参考：权威无后缀 `vibevenera-master.zip`。
- 当前版本：Source `0.31.0-dev.182`，Android `versionCode=182`。
- 当前环境没有 Flutter/Dart/Rust/完整 Android SDK/NDK，因此不宣称 `flutter analyze`、Flutter/Dart tests、APK build或Rust tests已执行通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py`仅在该继承缺件处停止，本轮未从旧包补入。

## Trace 与根因验证

- dev.181 production control propagation已在设备trace中出现：origin read-through带 `controlledFallback=true`，current origin可携带 priority 1000，因此本轮不继续扩大NetLane/Venera抢占分支。
- 缓存页可在几十到数百毫秒首帧；多个未缓存current仍由约2秒到十余秒 `sourceWait`主导，native decode通常只有几十毫秒。
- 对照 VibeVenera确认 Reader `streamOnly` direct-stream路径不使用 `images.dart` 的64 KiB/256 KiB coalescing；该聚合属于非direct-stream分支。
- ZIC dev.179 transport层64/256 KiB framing与既有 `DownloadJob` 16 KiB startup / 64 KiB source-progress aggregation形成双重owner，可能推迟source growth和早期decode-prefix尝试。

## 实现验证

- 删除 `RhttpChunkCoalescer` 与其transport专用回归。
- `RhttpSourceResourceDirectTransport`通过媒体前缀验证后直接转发raw stream chunk，并继续保留TaskControl cancellation、range/validator、media prefix与source-owned fallback语义。
- `DownloadJob`继续作为唯一page-body chunk aggregation owner：首批约16 KiB，随后按64 KiB `sourceProgressQuantumBytes`提交session。
- dev.181 controlled read-through、dev.176 response abort、retained receiving、current pressure、7/3、2/1、5/3/2均未改变。

## 已实际通过

- `check_dart_structure.py`：343 Dart files / 129 test files。
- `test_dart_library_directive_order.py`、`check_documentation.py`、`test_dev139_current_documentation.py`。
- dev.75–97、dev.99–182全部历史 Python ownership gates明确通过；dev.98仅因继承的pinned libwebp归档缺失排除。
- Reader streaming、Pipeline demand stability、source-resource atomic binding、UI architecture。
- Venera bootstrap / Reader preflight / network policy。
- Mihon entry、Payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android dependency mutation、texture bridge Kotlin compile、native header、Python bytecode与shell syntax检查。

## Repository check

`python3 tool/check_repo.py`只停止于继承缺件：

`third_party/source_archives/libwebp-1.6.0.zip`

没有新的repository错误。

## Patch 预回放

写入本validation前，从全新dev.181生成预Patch并实际执行 `git apply --check --index` / `git apply --index`；产品工作树与回放树均有1171个发行文件，missing=0、extra=0、content diff=0。预回放同时发现dev.175历史gate有一个工作目录 `0644 -> 0755` 的无关mode污染，已按dev.181基线恢复，不进入正式Patch。

加入本validation后的候选回放包含1172个发行文件、17个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式Patch并从全新dev.181第二次执行 `git apply --check --index` / `git apply --index` 与完整manifest/mode比较。最终发行只有在冻结后的结果仍为1172 / 0 / 0 / 0 / 0时成立。
