# dev.234 Validation Results

## 设备证据输入

01:41真机Trace共7964条事件。dev.233预期得到确认：`taskFailed=0`；38次`verified-transfer-acquire-alias`中4次`candidateOwners=2`全部选择`preferred-existing-owner`，`rejected-ambiguous-existing-owners=0`。promotion自动handoff重复probe仅剩2次`skip-existing`。新的开放证据是四次Reader dispose时共享physical registry依次为43、50、100、107，且`physicalTransferOwnerShared=true`、`handoffDrainMicros=0`。

## 本环境可执行验证

- `tool/check_documentation.py`：PASS。
- `tool/check_dart_structure.py`：PASS，354 Dart files / 132 test files。
- dev.205–dev.234 ownership/version/partial gates：30/30 PASS，以8 workers并行执行。
- `tool/test_reader_streaming_contract.py`：PASS。
- `tool/test_pipeline_demand_stability.py`：PASS。
- `tool/test_pipeline_runtime_compile_boundary.py`：PASS。
- `tool/test_ui_architecture_contract.py`：PASS。
- `tool/check_test_quarantine.py`：PASS。
- Android runtime dependency check/test：PASS。
- `tool/test_texture_bridge_kotlin_compile.py`：PASS；当前环境存在Kotlin compiler。
- `tool/check.sh`：未完成；在入口因唯一dev.233基线缺失锁定`third_party/source_archives/libwebp-1.6.0.zip`而失败。本轮未从历史包补入该archive。

## 当前环境不可执行

当前环境无Dart SDK、Flutter SDK、Cargo，因此新增Dart行为测试、Flutter analyze/test、App build及Rust tests未执行，不得声明`Verified-toolchain`或`Verified-device`。

## 新行为测试源码

`packages/downloads/test/physical_transfer_retention_test.dart`新增以下回归：promoted idle在ordinary durable handoff后退休；缺少immutable handoff authority时promoted hot body必须保留；idle partial预算压力cold-store victim；equivalence-only durable ownership不被退休升级成exact copy；cold partial写失败保留hot owner；retire同步清理acquire-time alias。

## 发布前结论

dev.234在当前环境达到`Verified-static`。新retention行为仍需下一份真机Trace确认：共享physical session规模应稳定受界；`session-partial-handoff action=stored`仅应以`reason=hot-retention-pressure`或runtime dispose出现；`composition-physical-retention`应能归因promoted/partial/empty retirement。
