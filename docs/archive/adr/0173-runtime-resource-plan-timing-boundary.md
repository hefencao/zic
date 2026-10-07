# ADR 0173：Runtime Resource-Plan Timing 编译边界与耦合收口

## 状态

Accepted。补充 ADR 0172 的 observability 实现边界；不改变 dev.189 的 Venera current-only 动态抢占、previous pressure、单 invocation 或 Reader 固定参数。

## 问题

用户本地编译 dev.189 报错：

`runtime_source_adapter.dart:804:7: Error: No named parameter with the name 'onTiming'.`

根因不是 session `_invoke` 缺少实现，而是接口半迁移：session 私有 `_invoke(...)` 已新增可选 `onTiming`，但 `_RuntimeBrowsableComicSource` 只持有窄化 `_RuntimeInvoke` 函数类型；该 typedef 仍只暴露 `TaskControl? control`。经 `_invoke` 字段调用时，静态函数类型因此拒绝 `onTiming:`。

简单给 `_RuntimeInvoke` 增加 timing callback 虽可消除当前错误，却会把只服务于 Reader resource-plan trace 的内部观测能力扩散给 browse/details/settings/account 等所有 runtime source 调用，形成不必要耦合。

## 决策

1. 通用 `_RuntimeInvoke` 保持原职责：operation + source id + arguments + scheduler `TaskControl`，不暴露 timing callback。
2. session 内部把 invocation 执行收敛为 `_invokeMeasured`，成功时返回私有 `_RuntimeInvocationResult(payload, gateWaitMicros, runtimeInvocationMicros)`；普通 `_invoke` 只取 payload。
3. 仅 resolve-resource constructor seam 注入 `_RuntimeResolveResourceInvoke`。它固定执行 `resolveResource` operation并返回 `_RuntimeInvocationResult`；source adapter继续拥有 runtime payload→`ComicResourceRequest` 的 schema/domain 转译，并在此处合并 gate/runtime diagnostics。
4. 删除 callback 式 `onTiming`，避免以后再次出现“实现签名已变、持有的函数类型未变”的半迁移。
5. `ComicResourceRequest.diagnostics` 继续作为只读 observability seam；显式 `sourcePlan*` key 不得进入 sessions、pipeline_runtime 或 App policy。scheduler/retry/cache不得读取这些字段改变行为。
6. 不改变 Venera requestId cancellation、single-invocation permit、780/1000 priority、5路 network、7/3窗口或其它 dev.189 行为。

## 后果

- 本轮编译错误的函数类型根因被消除，而不是把 timing 参数扩散到所有 runtime 调用。
- source adapter仍是 serialized runtime schema 与 catalog domain model 的唯一转译层；session只交付 payload与自身 gate/runtime timing，不开始解析 `ComicResourceRequest`。
- diagnostics保持观测通道而非控制通道；后续若新增 plan stage，不得通过 generic runtime invoke 或 Reader/Pipeline policy 引入第二套 ownership。
