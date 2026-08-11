# dev.214 验证结果

日期：2026-08-11
目标版本：`0.31.0-dev.214` / App `0.31.0+214`

## 当前环境

- `dart`：不可用。
- `flutter`：不可用。
- Java：`/usr/bin/java`。
- Kotlin compiler：可用。
- CMake / Ninja：可用。
- Node / Git：可用。
- `third_party/source_archives/libwebp-1.6.0.zip`：基线缺失；按项目治理不得从早期版本或外部独立包补入。

因此本轮没有声称 `flutter analyze`、Dart test、Android APK build 或真机行为通过。

## 已通过

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`
- `python3 tool/check_test_quarantine.py`
- `python3 tool/test_ui_architecture_contract.py`
- `python3 tool/test_reader_streaming_contract.py`
- `python3 tool/test_pipeline_demand_stability.py`
- `python3 tool/test_dev177_vibevenera_retained_preemption_download_manager_route_first.py`
- `python3 tool/test_dev184_receiving_state_detach_current_previous_handoff.py`
- `python3 tool/test_dev199_cost_aware_full_body_catchup.py`
- `python3 tool/test_dev200_deferred_catchup_memory_two_tier_cost.py`
- `python3 tool/test_dev201_restart_cost_retention_preemption.py`
- `python3 tool/test_dev202_restart_cost_headroom_retention.py`
- `python3 tool/test_dev203_bounded_retention_rollback.py`
- `python3 tool/test_dev204_partial_headroom_venera_connection_reuse.py`（历史 gate 已由后续 ownership gate supersede）
- `python3 tool/test_dev205_reader_partial_lifecycle.py`（历史 gate 已由 dev.206 supersede）
- `python3 tool/test_dev206_download_owner_venera_rhttp_boundary.py`（含 Kotlin stub compile；仅未使用参数 warning）
- `python3 tool/test_dev207_version_reuse_vertical_anchor_owner.py`
- `python3 tool/test_dev208_version_relation_projection_bidirectional_reuse.py`
- `python3 tool/test_dev209_removed_version_signal_call_closure.py`
- `python3 tool/test_dev210_version_metadata_warm_reader_fast_partial_reuse.py`
- `python3 tool/test_dev211_version_equivalence_late_artifact_reuse.py`
- `python3 tool/test_dev212_version_mapping_decode_freshness.py`
- `python3 tool/test_dev213_equivalent_full_takeover_session_partial_boundary.py`
- `python3 tool/test_dev214_image_transfer_consumer_claims.py`

`dev214` gate明确检查：

1. `DownloadSession` 使用 scoped `DownloadDemandLease`；
2. effective priority 取 claim 最大值而不是求和；
3. registry-created session 不再伪造初始 consumer；
4. Reader coordinator 使用自己的 claim，Reader-path `DownloadJob` 不再 legacy attach；
5. 原 consumer 退出后若仍有 claim，不 cancel transfer，并将 NetLane priority 降到剩余有效值；
6. ownership 测试覆盖两 consumer 的独立 detach；
7. dev.214 没有提前引入 global transfer registry / cross-Reader hot partial；
8. 版本与治理文档已同步。

## 完整 `tool/check.sh`

执行：`bash tool/check.sh`。

结果：在 pinned libwebp source gate 停止：

`ERROR: pinned libwebp archive is missing: .../third_party/source_archives/libwebp-1.6.0.zip`

这是当前唯一代码基线已存在的 source-archive 缺失；本轮未从任何更早 ZIC 版本或独立 `libwebp-1.6.0.zip` 偷补。因此 `tool/check.sh` 不能记录为整体通过。

## 验证等级

- consumer-claim ownership / priority / detach 语义：`Verified-static`。
- Kotlin bridge 相关既有边界：`Verified-toolchain`（仅对应现有 Kotlin stub gate）。
- Dart/Flutter 编译：`Unverified`。
- Android 构建/真机：`Unverified`。
- cross-Reader active partial sharing：**未实现，也未验证**；本轮只建立其前置 demand ownership。
