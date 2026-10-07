# dev.201 验证结果

## 变更边界

- 唯一基线：dev.200完整ZIP。
- 生产修改限定于 sessions 的 DownloadJob/NetLane/LiveCoordinator、telemetry新增一个preemption事件，以及trace filter收录该事件。
- 不修改Reader/Pipeline demand priority、network=5、Range/CRC continuity proof、playable artifact authority、DecodeSession、rhttp、Venera/Mihon。
- restart cost只影响active victim selection，不改变admission priority。

## 回归合同

Dart tests新增/扩展：

- 780 full-body task在约10s/8MiB restart cost后，与无成本800同时active；900 transition必须取消800而保留780；
- restart cost饱和后，1000 current仍必须能preempt该780；
- full-body ignored-Range完成时CancelToken记录整个response restart-cost bytes；被admission defer的200 response不得启动restart-cost tracking。

当前环境无Dart/Flutter SDK，上述Dart行为测试写入但不能声称已执行。

## 已执行静态/工具链验证

通过：

- `git diff --check`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.175–dev.201 受影响 release/ownership gates；其中 dev.175 历史 gate 原先绑定 `CancelToken({int priority = 0})` 精确源码文本，dev.201 增加可选 clock 后误报，已改为验证默认 priority=0、mutable updatePriority 与 token propagation 的语义，不恢复旧constructor字面量。
- source-resource atomic/binding、Reader streaming、Pipeline demand、UI architecture
- Debug Trace filter/export、frame pipeline trace analyzer
- Venera network/native/preflight/headers/cache/bootstrap
- Mihon entry/payload/ABI/classloader/read-only/chapter、shared external login
- Cloudflare typed classifier Kotlin compile/behavior
- texture schedule timing、Android texture bridge Kotlin compile、Android runtime dependency contract
- `python3 -m compileall -q tool`，生成的 `__pycache__/*.pyc` 已清除

组合平台批跑在 Cloudflare Kotlin 段达到单次执行窗口，随后从 Cloudflare 开始独立重跑并通过；未把 timeout 记作产品通过或失败。

实际执行 `bash tool/check.sh`，仍在 dev.200 权威基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 前置检查退出；没有从旧版本补入。

当前环境无 Dart/Flutter SDK，存在 Kotlin/Java。因此新增 Dart 行为测试未执行，不能声称通过 `dart analyze`、Dart/Flutter tests 或完整 Flutter Android build。

## Patch replay / package

authoritative candidate replay 与写入candidate结果后的 pre-final replay均从原始 dev.200 完整 ZIP fresh extract初始化baseline Git后实际执行；两轮均满足：

- `git apply --check --index`：PASS
- `git apply --index`：PASS
- work/replay：1243 / 1243
- missing=0、extra=0、content/executable-mode different=0
- ADR0182、dev.201两份audit与dev.201 gate均实际包含在patch。

pre-final完整ZIP用系统`zip`生成、系统`unzip` fresh extract后，与冻结工作树同为1243个有效文件，missing=0、extra=0、content/executable-mode different=0；`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo`均未进入ZIP。

本审计文本冻结后仍需重新生成最终patch，并执行最后一次fresh dev.200 replay与同冻结树ZIP比对；若最终数字不同则不得交付。
