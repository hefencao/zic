# dev.221 验证结果

目标版本：`0.31.0-dev.221` / App `0.31.0+221`

## 已执行

- `tool/check_documentation.py`：通过；`NEXT_CHAT_HANDOFF.md`保持80行责任上限。
- `tool/check_dart_structure.py`：通过（351 Dart files / 131 test files）。
- `tool/test_reader_streaming_contract.py`、`tool/test_pipeline_demand_stability.py`：通过。
- dev.170、174、175、177、183–189、205–221适用ownership/抢占/partial/Reader边界gate：通过；dev.206 Kotlin facade stub实际编译通过。
- `git diff --check`：通过。

## 行为测试源码

新增/更新Dart回归覆盖：physical `residentCacheBacked=true`且`artifact.committedLength==0`时，late Reader必须从外部encoded-byte authority重建完整sealed projection；late coordinator测试显式提供resident replay source。当前环境没有Dart/Flutter SDK，因此这些Dart/Flutter tests未实际执行，也未声称`flutter analyze`/APK build通过。

## 完整门禁限制

`bash tool/check.sh`在`tool/check_repo.py`阶段停止：唯一dev.220基线缺少`third_party/source_archives/libwebp-1.6.0.zip`。未从旧版本或独立参考包补入该archive。

## 结论

dev.221只改变resident encoded-source replay ownership：physical session不再把resident committed length等同于session artifact正文；Reader-local replay由composition cache/local immutable source提供并经过共享artifact-read scheduler。NetLane、水位、retry、cache持久化owner、transport与verified TransferKey均未修改。
