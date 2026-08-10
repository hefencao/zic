# dev.203 验证结果

## 变更范围

相对 dev.202，production runtime 只将 `packages/sessions/lib/src/net_lane.dart` 的 restart-cost retention 投影精确恢复为 dev.201 bounded 公式；`packages/sessions/test/net_lane_test.dart` 同步恢复 dev.201 owner-test预期。DownloadJob、DownloadSession、LiveCoordinator、Range/rhttp、Venera/Mihon、DecodeSession、Reader/Pipeline production code不修改。

## 已执行验证

通过：

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.175–192、dev.195–203 连续 ownership/release gates
- source-resource atomic binding、Reader streaming/output、Pipeline demand stability、UI architecture
- Venera network policy/native binary/response headers/Reader preflight/source-requested cache/bootstrap
- Android Trace export、frame pipeline analyzer
- Mihon entry/payload Context/ABI routing/classloader/read-only payload/chapter contract
- shared external login bridge
- Cloudflare typed classifier Kotlin compile/behavior
- texture schedule timing、Android texture bridge Kotlin compile
- Android runtime dependency contract

Cloudflare Kotlin 在一次组合批跑中超过单次120秒执行窗口；随后单独重跑并通过。该 timeout 未记作产品失败或通过。

当前环境没有 Dart/Flutter SDK，因此没有执行并不得声称通过 `dart analyze`、Dart/Flutter tests 或完整 Flutter Android build。已有 Dart owner tests仍保留在仓库中供用户本地验证。

完整 `bash tool/check.sh` 实际执行，并在第一项 repo preflight 因权威 dev.202 基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` 退出；未从旧版本补入该 archive。

## Trace 对照结论

- dev.201 Trace：first-frame 17次，中位约80.4ms、P90约1.94s、最坏约2.86s；136次download preemption / 约57.32s。
- dev.202 Trace：first-frame 30次，中位约63.8ms、P90约1.60s、最坏约6.84s；118次download preemption / 约110.47s。
- dev.202 headroom降低了preemption churn，但没有改善用户设备体感，且允许base=0历史成本获得数百点retention。最坏首帧由current自身sourceWait/request-plan/host-open主导，因此Venera冷尾延迟保留为独立后续问题。

## Replay / package

authoritative candidate replay 与写入candidate结果后的 pre-final replay均从原始 dev.202 完整 ZIP fresh extract初始化baseline Git后执行；两轮均满足：

- `git apply --check --index`：PASS
- `git apply --index`：PASS
- work / replay：1251 / 1251
- missing=0、extra=0、内容 SHA-256 / executable-bit different=0
- ADR0184、两份 dev.203 audit 与 dev.203 gate 均实际进入 patch。

pre-final完整 ZIP用系统`zip`生成、系统`unzip` fresh extract后，与工作树同为1251个有效文件，missing=0、extra=0、内容/executable-bit different=0；`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo`均未进入ZIP。

本审计文本冻结后仍需重新生成最终patch，并执行最后一次fresh dev.202 replay与同冻结树ZIP比对；若最终结果与上述数字不同则不得交付。
