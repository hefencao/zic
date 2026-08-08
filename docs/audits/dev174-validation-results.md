# dev.174 验证结果

## 基线与参考

- 唯一代码基线：`zic_v0.31.0-dev.173_migration-version-update-badge-owner.zip`。
- 只读对照：文件库权威无后缀 `vibevenera-master.zip`；没有使用其源码替代 ZIC owner，也没有从旧 ZIC版本复制实现。
- 发行版本：Source `0.31.0-dev.174`，Android `versionCode=174`。
- 当前环境有 Python/Git/Kotlin/JVM/Node，但没有 Dart/Flutter SDK和完整 Android SDK/NDK，因此不宣称 `dart test`、`flutter analyze`、Flutter tests或 APK build已执行通过。

## 根因对照

VibeVenera与 dev.173 ZIC都已具有：active priority migration、current high priority、normal lane满载、低 rank running cancellation、单一 `max+1` handoff、取消任务真实结束前保留 running permit。

关键差异位于 handoff饱和分支：VibeVenera在 `running >= max + reserved` 时仍对队首 high-priority task调用一次最低 rank running preemption后返回；dev.173 ZIC则先在 `eligible`过滤里排除这个 current，随后 `eligible.isEmpty`直接 break。因此一个慢取消占住 handoff时，新的 current没有机会继续推动其它 prefetch让位。

## 实现验证

- `NetLane._pump()`在无可立即 admission任务时查找最高 blocked high-priority pending并调用原 `_preemptLowestRunningFor`。
- victim过滤继续跳过 `!preemptible` 与 `token.cancelled`，并保持 bucket/full与 priority差阈值。
- blocked current不会在 `running >= handoffCapacity`时直接启动；active/bucket permit仍只在 task真正 `whenComplete`后释放。
- network=5、reserved=1、current threshold=1000、preemption threshold=40以及 Reader 7/3、2/1、7/5/3/2策略均未修改。
- 新 Dart回归使用真实 5+1规模：首个 victim收到 cancel后故意不退出，第二个 current必须继续取消另一条低 rank prefetch，并在真实 permit释放后启动，不等待首个慢取消或无关预取自然结束。

## 已执行门禁

已明确通过：

- `check_dart_structure.py`：341 Dart files / 129 test files。
- `test_dart_library_directive_order.py`、Python compile与全部 shell syntax。
- dev.120–dev.174 历史 Python ownership gates：分段执行，全部得到明确 PASS；批次因累计 Kotlin编译触发工具窗口时从断点继续，没有把 timeout当 PASS。
- 重点：dev.123 download preemption、dev.138 VibeVenera target-page independence、dev.139 documentation、dev.172/173、dev.174 gate。
- `test_reader_streaming_contract.py`、`test_pipeline_demand_stability.py`、`test_source_resource_binding.py`、`test_ui_architecture_contract.py`、Venera bootstrap、Mihon payload Context Kotlin compile。
- `check_documentation.py`；`ARCHITECTURE.md=420`行、`NEXT_CHAT_HANDOFF.md=80`行。

由于没有 Dart SDK，新增的 `packages/sessions/test/net_lane_test.dart` 行为测试已写入但未在当前环境实际执行；本轮不把 Python static gate描述成 Dart runtime验证。

## Repository check

`python3 tool/check_repo.py`仍只停止于 dev.173基线既有缺件：

`third_party/source_archives/libwebp-1.6.0.zip`

本轮未从旧包补入。

## Patch 预回放

写入本文件前，从全新 dev.173 项目根生成候选 Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

预回放含 1136 个发行文件、14个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本 validation后的候选回放包含1137个发行文件、15个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式 Patch并从全新 dev.173再次执行 `git apply --check --index` / `git apply --index` 与完整 file-set/content/mode比较。最终发行只有在冻结后的结果仍为1137 / 0 / 0 / 0 / 0时成立。
