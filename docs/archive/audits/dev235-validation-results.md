# dev.235 Validation Results

## Trace输入
`zic-debug-trace-2026-08-12T02-58-57.jsonl`：5893条事件。15次verified acquire alias全部复用既有physical owner，其中4次multi-owner均选择`preferred-existing-owner`；4次Reader dispose前physical session数41、41、41、42。4条full-body catch-up累计`duplicatePrefixBytes=13,466,264`。另有3次unsealed `partial-source` decode task failure，独立保留为后续decode/backpressure审计项。

## 源码/治理验证
- `tool/check_dart_structure.py`：PASS，354 Dart files / 132 test files。
- `tool/check_documentation.py`：PASS。
- dev.205–dev.235 ownership/version/partial gates：31/31 PASS，以8 workers并行执行。
- `check_test_quarantine.py`、Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming contract、UI architecture、Android runtime dependency closure、Android texture bridge Kotlin compile：PASS。
- dev.235 gate确认production transport/replay路径不再直接使用`session.validators`；`DownloadJob`、resident replay、Pipeline immutable replay、cold partial persistence均经actual URI scoped `resumeValidatorsFor(...)`。
- Dart行为回归源码覆盖foreign provider validator不发送、physical alias改走validatorless overlap、cold physical partial不持久化foreign validator、v2无scope metadata保留partial/totalLength但丢弃validator。当前环境无Dart/Flutter SDK，因此这些测试未实际执行，不声明`flutter analyze`/Dart tests/APK build通过。

## 完整入口
`bash tool/check.sh`在repository入口即被唯一dev.234基线缺失的锁定`third_party/source_archives/libwebp-1.6.0.zip`阻断。未从任何历史包补入依赖。当前环境亦无Cargo，因此不声明Rust tests。

## 验证级别
dev.235当前达到`Verified-static`，并具有当前真机Trace对根因的输入证据；provider-scoped validator修复本身仍需下一份设备Trace验证。预期跨provider physical alias出现`providerValidatorMismatch=true`并使用`validatorless-range-probe`，不再因foreign validator触发`strongRangeRejected→200 full-body`；同时应显著减少`duplicatePrefixBytes`。
