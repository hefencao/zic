# dev.216 验证结果

日期：2026-08-11
目标版本：`0.31.0-dev.216` / App `0.31.0+216`

## 当前环境

- `dart`：不可用。
- `flutter`：不可用。
- Kotlin compiler：可用。
- CMake / Ninja / Node / Git / Cargo：可用。
- `third_party/source_archives/libwebp-1.6.0.zip`：唯一dev.215基线继续缺失；未从早期版本或独立包补入。

因此没有声称`flutter analyze`、Dart tests、APK build或真机行为通过。

## 已通过

本轮实际执行并通过：

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`（351 Dart files / 131 test files）
- `python3 tool/check_test_quarantine.py`
- `python3 tool/test_ui_architecture_contract.py`
- `python3 tool/test_reader_streaming_contract.py`
- `python3 tool/test_pipeline_demand_stability.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.170、177、184、199–203 gates
- dev.204/205 historical superseded gates
- `python3 tool/test_dev206_download_owner_venera_rhttp_boundary.py`（包含Kotlin facade stub compile；仅未使用参数warning）
- dev.207–215 existing ownership/regression gates
- `python3 tool/test_dev216_composition_transfer_owner.py`

其中dev.206历史gate已按新的owner边界兼容：dev.206原本要求Reader session dispose执行cold partial drain；
dev.216后该责任必须由composition physical owner在final-unclaimed/writer-exit边界执行，不能把Reader drain重新引回生产代码。

## dev.216 新增行为证据

新增Dart测试源码覆盖：

1. 两个consumer请求同一exact `DownloadId`时只有一个registry session/active writer/transport open；
2. active provider Reader退出后，其task先物理退出；remaining consumer保留同一session与降级priority，并只重新open一次完成；
3. final consumer退出且已有committed prefix时，writer退出后physical owner只执行一次partial persistence，长度等于authoritative committed length。

当前没有Dart SDK，因此这些Dart测试**已编写并静态审计但未执行**，验证等级不是runtime-pass。

## 完整 `tool/check.sh`

实际执行 `bash tool/check.sh`，仍在最前部 `tool/check_repo.py` 的pinned libwebp presence检查停止：

`ERROR: pinned libwebp archive is missing: .../third_party/source_archives/libwebp-1.6.0.zip`

这是唯一dev.215基线已有缺失，按治理规则没有补入。不能记录完整`tool/check.sh`整体通过。

为审查dev.216迁移，另单独执行了与当前ownership直接相关的结构/历史gates并全部通过；没有把“人工跳过libwebp”的临时扩展脚本计作正式完整gate。

## 验证等级

- composition physical registry/network/retry/terminal/workspace ownership：`Verified-static`。
- Reader provider detach barrier / exact-id single-writer协议：Dart测试已新增，`Unverified-runtime`（无Dart SDK）。
- final-unclaimed durable partial drain ownership：`Verified-static`；Dart行为测试未执行。
- Kotlin resolver既有边界：`Verified-toolchain`（dev.206 stub compile）。
- Dart/Flutter编译与测试：`Unverified`。
- Android build/真机：`Unverified`。
- verified cross-version TransferKey-before-acquire：**未实现**；仍是下一阶段。
