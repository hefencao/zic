# dev.200 验证结果

## 变更边界

- 唯一基线：`zic_v0.31.0-dev.199_cost-aware-full-body-catchup-admission.zip`。
- 生产逻辑只修改`packages/sessions/lib/src/live_coordinator.dart`：defer从当前demand生命周期内的Set升级为按`DownloadId + committedLength`记忆，并把full-body admission改为1/8 MiB两级门槛。
- DownloadJob、DownloadSession、DecodeSession、Reader/Pipeline、NetLane、rhttp、Venera/Mihon production逻辑不变。
- 不持久化endpoint“永不支持Range”能力；partial长度变化或priority达到当前成本门槛即可解除defer并重新probe。

## 回归合同

`live_coordinator_test.dart`扩展：

- 中等partial在800/780 defer后，demand完整detach再以780 re-add仍不得产生第二个request；升到820后重新probe并完成；
- `>=8 MiB` partial在next=820只允许probe后defer，不读取full body；升到transition=900后重新probe并完成。

当前环境没有Dart/Flutter SDK，因此上述Dart行为测试已写入但未执行，不能声称通过。

## 已执行并通过

- `git diff --check`
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.175–dev.200现存连续release/ownership gates
- source-resource atomic binding、Reader streaming/output、Pipeline demand stability、UI architecture、frame trace analyzer、Android trace export
- Venera network policy、response headers、native binary、Reader preflight、source-requested network cache、bootstrap
- Mihon entry、payload Context、ABI routing、classloader、read-only payload、chapter contract
- shared external login、external source settings
- Cloudflare typed classifier Kotlin compile/behavior
- texture schedule timing、Android texture bridge Kotlin compile、Android runtime dependencies、vertical geometry/cover trace
- `bash tool/check_native_header.sh`

两次组合平台命令分别在Mihon payload与external-source-settings附近达到单次执行窗口；均从中断项拆开继续，后续相关合同全部实际通过。Android texture Kotlin只出现测试stub unused-parameter warning。

环境探测：`dart`不存在、`flutter`不存在、`kotlinc`与`java`存在。因此没有执行并不得声称通过`dart analyze`、Dart/Flutter tests或完整Flutter Android build。

## 完整检查

实际执行`bash tool/check.sh`，在第一项因dev.199权威基线继承缺失的`third_party/source_archives/libwebp-1.6.0.zip`退出。没有从dev.198或其它旧版本/工作目录补入该archive。

## Patch replay / package

authoritative candidate replay与写回candidate结果后的pre-final replay均从原始dev.199完整ZIP fresh extract初始化baseline Git后执行；两轮均满足：

- `git apply --check --index`：通过；
- `git apply --index`：通过；
- 工作树 / replay：1239 / 1239个有效文件；
- missing=0、extra=0、内容SHA-256 / executable-mode diff=0；
- ADR0181、dev.200两份audit与dev.200 gate均实际包含在patch。

pre-final完整ZIP fresh extract后同样为1239 / 1239，missing=0、extra=0、内容/executable-mode diff=0；`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo`禁入项为0。

本审计文本冻结后仍必须重新生成最终patch并执行最后一次fresh dev.199 replay与同冻结树ZIP比对；只有数字仍完全一致才允许交付。
