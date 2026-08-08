# dev.172 根因审计：Venera / Mihon Browse 同时失败

## 输入证据

- `错误报告(20260808-142635).txt`
- `zic-debug-trace-2026-08-08T14-27-09.jsonl`

## Trace / 错误报告结论

错误报告栈在 `_RuntimeBrowsableComicSource._browse` 构造 `ExternalPluginRuntimeRequest` 时进入 `runtime_protocol.dart::_validateArguments/_expectKeys`，抛出 `FormatException: runtime request arguments do not match operation`。失败发生在 connection/runtime/plugin调用之前。

trace只有32条事件：external plugin host已 ready 后，`venera:ehentai` 普通 browse以 `filterViewActive=false/filterCount=0`开始并约0.2 ms内 FormatException失败；随后 Mihon 18comic与roumanwu的普通 latest browse同样在约0.5–0.9 ms内以 FormatException失败。多个生态同时同步失败排除了站点网络、Cookie、cleartext、图片 decode或单个插件ABI作为共同根因。

## 根因

dev.171 为 browse adapter payload增加：

`useFilters: bool`

并让 Mihon runtime driver消费该字段，但 `runtime_protocol.dart` browse `_expectKeys`仍严格要求旧集合：

`query / offset / limit / sectionId / filterState`

因此 adapter每次都多发一个 validator不认识的字段。即使普通 browse发送 `useFilters=false`，仍会在 Dart本地校验失败。Venera虽不使用 Mihon filter语义，也共享同一个 external browse wire protocol，因此一起失效。

## 为什么上一轮门禁没有发现

- 当前发行环境没有 Dart/Flutter SDK，`runtime_source_adapter_test`未实际执行；该测试若执行会直接触发同一 FormatException。
- dev.171 owner gate检查了 adapter payload与 Mihon driver，却没有检查 `runtime_protocol` browse schema。
- dev.171 gate未接入 `tool/check.sh`，因此完整 repository check也没有自动覆盖它。

## 修复

- typed browse factory新增显式 `useFilters=false`并序列化该字段。
- `_expectKeys`支持显式 optional字段；browse只把 `useFilters`列为 optional，仍拒绝其它未知字段。
- validator要求 `useFilters`若存在必须为 bool；旧 schema v1 browse可不带该字段。
- runtime protocol tests覆盖新字段 round-trip、旧 v1缺省兼容、非法类型与未知字段拒绝。
- `tool/check.sh`补入 dev.171，并加入 dev.172 protocol gate，静态检查 protocol/factory/adapter/Mihon driver四端。

## 未改变

- Mihon Filter ABI/schema/state语义不变。
- Venera browse section/search逻辑不变。
- WNACG cleartext能力与 Reader terminal retry逻辑不变。
- source lifecycle、cache、artwork和 Reader/Pipeline参数不变。
