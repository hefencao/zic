# dev.202 验证结果

## 变更边界

- 唯一基线：dev.201完整ZIP。
- production逻辑只修改`packages/sessions/lib/src/net_lane.dart`的restart-cost retention rank投影；不修改DownloadJob事实采集、LiveCoordinator demand/admission、Reader/Pipeline、Range/rhttp、DecodeSession、Venera/Mihon。
- dev.201固定最多+100被headroom比例投影替代；pending/admission priority不变，1000 current-safe margin不变。

## 行为合同

Dart test新增/调整：base降到0但已投入约5.88s/6.29MiB时，incoming800应优先取消无成本640 victim；restart cost饱和后1000 current仍将780 victim按retention=960抢占。当前环境如无Dart/Flutter，不得声称这些行为测试已运行。

## 已执行验证

通过：

- `git diff --check`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.175–dev.202受影响release/ownership gates，包括dev.199/200 admission/defer、dev.201 restart-cost facts/current-safe与dev.202 headroom gate
- source-resource atomic/binding、Reader streaming、Pipeline demand、UI architecture
- Android Trace export、frame pipeline analyzer
- Venera network/native/preflight/headers/cache/bootstrap
- Mihon entry/payload/read-only/ABI/classloader/chapter、shared external login
- Cloudflare typed classifier Kotlin compile/behavior
- texture schedule timing、Android texture bridge Kotlin compile、Android runtime dependency contract
- `python3 -m compileall -q tool`；生成bytecode已清理

组合平台批跑在Cloudflare Kotlin段达到单次执行窗口，随后独立重跑并通过；timeout没有记作产品失败或通过。

实际执行`bash tool/check.sh`，仍在dev.201权威基线继承缺失的`third_party/source_archives/libwebp-1.6.0.zip`前置检查退出；没有从旧版本补入。当前环境无Dart/Flutter SDK，因此没有声称通过`dart analyze`、Dart/Flutter tests或完整Flutter Android build。

## Patch replay / package

authoritative candidate replay与写入candidate结果后的pre-final replay均从原始dev.201完整ZIP fresh extract初始化baseline Git后实际执行；两轮均满足：

- `git apply --check --index`：PASS
- `git apply --index`：PASS
- work/replay：1247 / 1247有效文件
- missing=0、extra=0、内容SHA-256 diff=0、executable-bit diff=0
- ADR0183、dev.202两份audit与dev.202 gate均实际进入patch。

首次比较脚本曾错误比较完整Unix mode，因原ZIP普通文件为0666而`git apply`重写文件为0644产生10个假阳性；逐文件SHA完全相同且可执行位相同。交付规范比较内容与executable mode。pre-final完整ZIP用系统zip生成、系统unzip fresh extract后，与冻结工作树同为1247个有效文件，missing=0、extra=0、内容/executable-bit diff=0，禁入项为0。

本审计文本冻结后仍需重新生成最终patch并执行最后一次fresh dev.201 replay与最终ZIP比对；最终数字若不同不得交付。
