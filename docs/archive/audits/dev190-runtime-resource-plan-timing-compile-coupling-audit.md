# dev.190 Runtime Resource-Plan Timing 编译与耦合审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.189_venera-current-only-dynamic-preemption-plan-stages.zip`
- 用户本地编译错误：`runtime_source_adapter.dart:804:7: Error: No named parameter with the name 'onTiming'.`

## 根因

`ExternalPluginRuntimeSession._invoke` 在 dev.189 为 gate/runtime stage timing增加了 `onTiming` 可选命名参数；但 `_RuntimeBrowsableComicSource` 并不持有该方法的原始静态类型，而是持有 `_RuntimeInvoke` typedef。该 typedef没有 `onTiming`，因此 `resolveResourceControlled` 经字段调用 `_invoke(... onTiming:)` 时静态编译失败。

这是 observability 改动的接口半迁移，不是 Dart 工具链差异，也不是 runtime 行为错误。dev.189 静态 Python gates只验证 token/结构，没有真实 Dart SDK，因此没有覆盖函数类型命名参数一致性。

## 收口审查

直接给 `_RuntimeInvoke` 增加 `onTiming` 会把 resource-plan 专用诊断扩到 browse/details/settings/account 等通用调用。仓库生产引用审查确认：

- `sourcePlanGateWaitMicros/sourcePlanRuntimeInvocationMicros` 只在 plugin_host resource-plan adapter生成；
- JS hook/bridge-network stage只在 Venera bridge生成；
- downloads 只透传这些 diagnostics进入 source trace；
- sessions、pipeline_runtime、App生产代码没有读取任何 `sourcePlan*` key作为 policy 输入。

因此保持现有只读 diagnostics seam，但把 timing invocation能力缩回 resolve-resource 专用私有边界。

## 修改

- `_invokeMeasured` 成为 session 内唯一 payload + gate/runtime timing执行实现；普通 `_invoke`只返回 payload。
- `_RuntimeInvoke` 保持无 timing 的通用函数类型。
- 新增 `_RuntimeResolveResourceInvoke`，只用于 source adapter 的 `resolveResourceControlled`。
- 删除 callback 式 `onTiming`；source adapter从 `_RuntimeInvocationResult` 合并两项 Dart stage diagnostics。
- 新增 dev.190 gate，既检查上述 compile-boundary，又禁止显式 `sourcePlan*` key进入 sessions/pipeline_runtime/App生产 policy。

## 未改变

- dev.189 current-only dynamic preemption；
- Venera single invocation / real `finished(requestId)` permit transfer；
- previous=780、current=1000、threshold40；
- Reader 7/3、decode 2/1、holder 7/5/3/2、network/decode/upload 5/3/2；
- JS hook与native最终图片HTTP ownership边界。
