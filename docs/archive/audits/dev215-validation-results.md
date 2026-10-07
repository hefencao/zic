# dev.215 验证结果

日期：2026-08-11
目标版本：`0.31.0-dev.215` / App `0.31.0+215`

## 当前环境

- `dart`：不可用。
- `flutter`：不可用。
- Java：`/usr/bin/java`。
- Kotlin compiler：可用。
- CMake / Ninja：可用。
- Node / Git：可用。
- `third_party/source_archives/libwebp-1.6.0.zip`：dev.214唯一基线继续缺失；未从早期版本或独立包补入。

因此没有声称 `flutter analyze`、Dart tests、APK build或真机行为通过。

## 已通过

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`
- `python3 tool/check_test_quarantine.py`
- `python3 tool/test_ui_architecture_contract.py`
- `python3 tool/test_reader_streaming_contract.py`
- `python3 tool/test_pipeline_demand_stability.py`
- dev.177、184、199–203 ownership/scheduling gates
- dev.204/205 historical superseded gates
- `python3 tool/test_dev206_download_owner_venera_rhttp_boundary.py`（含 Kotlin stub compile；仅未使用参数 warning）
- dev.207–214 existing regression/ownership gates
- `python3 tool/test_dev215_download_ingress_projection_split.py`
- `git diff --check`

`dev215` gate检查 physical `DownloadSession` 已移除唯一 native `Ingress`/`SourcePool` ownership，
Reader composition持有 `DownloadIngressProjectionRegistry`，DecodeSession只从显式 projection取source，
late committed-prefix 使用稳定边界同步附着，并且本轮没有提前创建 global physical registry。

## 完整 `tool/check.sh`

执行 `bash tool/check.sh` 后仍在 pinned libwebp source gate 停止：

`ERROR: pinned libwebp archive is missing: .../third_party/source_archives/libwebp-1.6.0.zip`

这是唯一基线已有缺失，按治理规则不补入。因此完整 gate不能记录为整体通过。

## 验证等级

- ingress projection ownership / constructor-call closure / Reader disposal ordering：`Verified-static`。
- late projection revision/epoch/committed-boundary协议：`Verified-static`；Dart行为测试已新增但当前无Dart SDK，未执行。
- Kotlin bridge既有边界：`Verified-toolchain`（对应dev.206 stub gate）。
- Dart/Flutter编译与测试：`Unverified`。
- Android build/真机：`Unverified`。
- cross-Reader physical transfer sharing：**未启用**；physical registry/network/retry仍待下一阶段提升。
