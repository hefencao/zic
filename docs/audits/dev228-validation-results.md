# dev.228 validation results

## 设备证据

- 输入：`zic-debug-trace-2026-08-11T15-57-17.jsonl`，7424条事件。
- `verified-transfer-acquire-alias=18`：8 promoted / 8 failed / 1 idle / 1 queued。
- `unsupported URI scheme: venera-resource=0`；`taskFailed=0`；`sessionBusy=0`；`writerBusy=0`；`decodeState=failed=0`。
- legacy `verified-equivalent-promotion-takeover=0`。
- `session-partial-handoff=62`：46 stored / 16 restored。
- `session-artifact-handoff=189`：93 skip-existing / 85 skip-cache-resident / 6 stored / 5 stored-resident-cache-authority。

## 当前环境验证

通过：

- `tool/check_documentation.py`；
- `tool/check_dart_structure.py`：352 Dart files / 131 test files；
- `tool/check_test_quarantine.py`；
- UI architecture / Reader streaming / Pipeline demand stability / Pipeline runtime compile boundary；
- dev.205–dev.228相关24条ownership/version/partial gate，8 workers并行全部通过；
- dev.206 Kotlin facade stub实际编译通过；
- dev.228 Phase E removal gate。

`bash tool/check.sh`仍只在唯一dev.227基线缺少`third_party/source_archives/libwebp-1.6.0.zip`处停止。当前环境没有Dart/Flutter SDK，因此Dart tests、Flutter analyzer、Flutter tests、APK build与真机二次验证未执行，不得标记为通过。

## pristine replay

预冻结 ordinary Patch、完整ZIP和Exact Replay均已独立验证：

- missing=0
- extra=0
- content=0
- executable-bit=0
- type=0

预最终ZIP扫描发现运行门禁产生的`tool/__pycache__`与2个`.pyc`，已从候选树清理。最终冻结后 ordinary Patch、完整ZIP、Exact Replay 已再次独立执行，三路均为 missing=0 / extra=0 / content=0 / executable-bit=0 / type=0，完整ZIP banned entries=0，最终SHA256SUMS自检通过。
