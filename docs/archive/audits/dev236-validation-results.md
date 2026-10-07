# dev.236 validation results

## 已完成

- dev.205–236 ownership/version/partial gates：32/32 PASS，8 workers。
- `tool/check_dart_structure.py`：PASS（354 Dart files，132 test files）。
- `tool/check_documentation.py`：PASS，`ARCHITECTURE.md`保持420行责任预算。
- Pipeline runtime compile boundary、demand stability、Reader streaming、UI architecture、test quarantine：PASS。
- Android runtime dependency checks、texture bridge Kotlin compile：PASS。
- dev.236专项gate确认：progress publisher不再存在exact-key session mirror/observer fan-out；`ReaderBinding.accept`先于resolved physical session selection；ingress scope使用physical lifecycle ID；alias行为回归已登记。

## 环境阻断

- `tool/check.sh`在repo入口停止：唯一dev.235基线缺少锁定的`third_party/source_archives/libwebp-1.6.0.zip`；没有从历史版本补入。
- 当前环境无 Dart/Flutter/Cargo，因此新增Flutter行为测试、`flutter analyze`、App build与Rust tests未执行，不能宣称通过。

## 设备后续

- acquire-time alias页的进度应从resolved physical session既有committed fraction开始，而不是logical exact ID的0进度。
- 继续拆分03:34 Trace的19,782,164 `duplicatePrefixBytes`；provider-validator mismatch的6次64KiB overlap已属预期，剩余大块200 full-body catch-up独立处理。
- 继续追踪1次unsealed `partial-source` decode failure与dev.231 `stored-required-exact-alias`。
