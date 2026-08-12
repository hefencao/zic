# dev.232 validation results

- 00:38真机Trace：5096条有效JSONL事件；`taskFailed` 3次，均为未sealed WebP 的`partial-source / Failure(decode): frame decode failed`。受影响page随后随source增长恢复，其中page 212在约3.9 MiB与6.0 MiB失败、最终约14.6 MiB sealed后正常出帧。
- 同一Trace中`verified-transfer-acquire-alias` 22次，均为`joined-existing-physical`；`skip-verified-equivalent-durable` 17次；`stored-required-exact-alias` 0次，因此dev.231 required exact durable target的真机场景仍未被本Trace覆盖。
- 根因审计：`DownloadIngressProjection.rebuild()`可在`DownloadSession.epoch`不变时替换Reader-local `EncodedSource`；旧`DecodeSession._bind()`只按`SourceEpoch`判断cursor可复用，允许cursor继续绑定已被projection替换/释放的旧source handle。
- 修复：DecodeSession现在记录`_boundSource`；cursor复用同时要求`_epoch == epoch`且`identical(_boundSource, source)`。同epoch source replacement会释放旧cursor/holder并绑定当前source，不吞异常、不增加外层retry。
- 新增行为回归：`rebinds when ingress replaces encoded source inside the same epoch`；当前环境无Dart/Flutter SDK，测试源码已审计但不能记为实际Dart test PASS。
- `python3 tool/check_documentation.py`：PASS；`python3 tool/check_dart_structure.py`：PASS（352 Dart files / 131 test files）。
- dev.205–dev.232 ownership/version/partial gates：PASS（28项，8 workers）。
- Reader streaming、Pipeline demand stability、UI architecture、test quarantine、Pipeline runtime compile boundary：PASS。
- dev.206 Kotlin resolver facade stub与Android texture bridge Kotlin compile：PASS（仅stub unused-parameter warnings）。
- App版本与Android项目版本已同步为`0.31.0+232` / `versionCode=232`。
- `TERM=xterm bash tool/check.sh`：与dev.231相同，仅因唯一dev.231基线缺少`third_party/source_archives/libwebp-1.6.0.zip`在`check_repo.py`入口停止；未从历史包补入。
- 当前环境无Dart/Flutter/Cargo：Flutter analyze/tests、Dart行为测试、APK build与Rust tests未执行，不记为通过。
- clean ZIP、baseline→dev.232 Patch replay与exact tree compare在发行冻结后独立执行，结果记录于外部validation与Exact Replay报告。
