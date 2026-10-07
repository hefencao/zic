# dev.222 验证结果

目标版本：`0.31.0-dev.222` / App `0.31.0+222`

## 代码边界

- slider `onChanged` 通过 Reader scrub API 实时推进 navigation；`onChangeEnd` 不再是唯一跳页入口。
- 新增 `Interaction.scrubbing`，scrub RoleWindow 只含 current；行为回归源码要求计划严格为 1 download / 1 decode / 1 upload，priority 均为 current 1000。
- scrub end 强制 planning revision，恢复正常完整窗口；普通 Reader navigation、physical transfer owner、resident replay、NetLane/水位/retry 均未修改。
- 本轮没有加入固定毫秒 debounce；降载依据是明确的交互语义，而不是时间阈值。

## Trace 复核

输入：`zic-debug-trace-2026-08-11T11-35-28.jsonl`。

- 共 56 次 page host dispose，仅 6 次 `firstFrameReady=false`，生命周期约 0.07–0.64 秒；没有前一轮 6–9 秒长期黑页。
- `decodeState` 分布为 decoding=225、ready=206、waitingSource=41、idle=8，`failed=0`。
- `sessionBusy=0`、`writerBusy=0`；相邻逐字段相同的 physical Trace 为 0。
- Reader3 的 `pageCurrent` 从 page 87 直接跳到 228，证实 dev.220 release-only scrub 没有在拖动期间推进真实 Reader navigation。

## 实际执行并通过

- `tool/check_documentation.py`
- `tool/check_dart_structure.py`：351 Dart files / 131 test files
- `tool/test_ui_architecture_contract.py`
- `tool/test_reader_streaming_contract.py`
- `tool/test_pipeline_demand_stability.py`
- `tool/test_dev220_reader_scrub_trace_boundary.py`
- `tool/test_dev221_resident_replay_authority.py`
- `tool/test_dev222_live_scrub_foreground_demand.py`
- dev.170、174、175、177、183–192、199、205–219 的适用历史 ownership / preemption / partial gates
- dev.206 Kotlin facade stub compile（仅有 unused-parameter warning）

## 环境限制与未宣称项

- 当前环境无 Dart SDK、无 Flutter SDK，因此新增 Dart/Flutter unit/widget tests 未实际执行；不宣称 `dart test`、`flutter test`、`flutter analyze` 或 APK build 通过。
- `bash tool/check.sh` 在第一步停止：唯一 dev.221 基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`。本轮未从旧版本、参考包或独立 libwebp 包补入该 archive。
