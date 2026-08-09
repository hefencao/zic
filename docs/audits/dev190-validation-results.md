# dev.190 验证结果

## 已执行并通过

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.157–190 release/ownership gates
- dev.188 / dev.189 Venera dynamic-priority/current-only plan-stage gates
- dev.190 runtime resource-plan timing compile/coupling gate
- Node `tool/test_venera_bootstrap.py`
- Venera network policy / response headers / Reader preflight / native binary contracts
- source-resource atomic binding
- Reader streaming / Pipeline demand stability / UI architecture
- Android runtime dependency、vertical geometry/cover trace
- Mihon entry / payload / ABI / classloader / read-only / chapter contracts
- Cloudflare typed classifier Kotlin compile
- Android texture bridge Kotlin compile
- `bash tool/check_native_header.sh`

一次批量平台合同执行在 texture Kotlin compile 阶段超过单次命令窗口；该测试随后单独重新执行并通过，仅有stub未使用参数 warning，不能记为产品失败。

## 用户本地编译错误闭环

用户报告：

`runtime_source_adapter.dart:804:7: Error: No named parameter with the name 'onTiming'.`

源码审查确认 dev.189 的 session `_invoke` 与 `_RuntimeInvoke` typedef 发生命名参数半迁移。dev.190删除 callback 式 `onTiming`，通用 `_RuntimeInvoke` 恢复单一职责；resolve-resource 使用专用 `_RuntimeResolveResourceInvoke`，由 `_invokeMeasured` 返回 payload + timing。当前环境没有 Dart/Flutter SDK，因此不能宣称本机 `dart analyze`/Flutter build已实际通过；dev.190 gate专门冻结该静态函数类型边界，最终仍需用户本地工具链确认。

## 耦合审查

生产代码显式 `sourcePlan*` key只存在于：

- plugin_host source-plan adapter / Venera bridge：生成观测；
- downloads source transport：只读透传到 trace。

sessions、pipeline_runtime、App生产代码没有读取这些key；因此 diagnostics尚未形成第二调度/缓存/retry通道。dev.190 gate会拒绝后续把显式 `sourcePlan*` key引入这些policy层。

依赖方向未改变：plugin_host继续依赖catalog，downloads继续依赖catalog，没有新增plugin_host↔downloads反向依赖。serialized runtime payload→`ComicResourceRequest`转译仍由 source adapter承担，session没有开始解析catalog domain request。

## 完整 check.sh

实际执行 `bash tool/check.sh`，第一项仍因基线继承缺失而退出：

`third_party/source_archives/libwebp-1.6.0.zip`

没有从旧ZIC包或其它基线注入该archive，因此 pinned libwebp host build/smoke不宣称通过。

## 当前环境未验证

- Dart/Flutter SDK不存在：Dart analyzer、plugin_host Dart tests、Flutter tests与App build未执行。
- Android完整SDK/NDK App debug/release build未执行。
- 本轮只修 compile boundary/内部耦合，不产生新的真机性能结论。

## Patch replay

最终候选patch从原始 dev.189完整ZIP重新解压的干净副本验证：`git apply --check --index` 与 `git apply --index` 均通过；`.zic-workspace.json`应用前后均不存在；排除`.git`、workspace与Python缓存后，工作树/replay树共1204个文件，内容SHA-256与executable mode逐项一致，无missing/extra/different。最终审计文本写回后重新生成patch并再次fresh replay。最终完整ZIP解压后也与工作树1204/1204逐项一致，且不含`.git`、`.zic-workspace.json`或Python缓存。
