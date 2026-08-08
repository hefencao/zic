# ADR 0155：External Browse Runtime Protocol 字段所有权

状态：Accepted

## 背景

dev.171 为独立 filter view 增加 `useFilters` request mode。Catalog 与 source adapter 已发送该字段，Mihon runtime driver也已读取它，但 `ExternalPluginRuntimeRequest` 的 browse validator仍只允许旧字段集合。由于 runtime request在 Dart侧构造时先执行严格 `_expectKeys`，Venera与Mihon所有 browse都在真正进入插件 runtime前同步失败。

当前 wire schema仍为 v1。`useFilters` 是同一 browse operation的 additive mode字段，不应为了一个向后兼容的新增字段整体升级协议，也不能通过接受任意未知字段绕过校验。

## 决策

1. `ExternalPluginRuntimeRequest.browse` typed factory必须显式生成 `useFilters`，默认 false。
2. browse wire validator把 `useFilters`声明为唯一明确的可选 additive字段；旧 schema v1请求可缺省它，消费端按 false解释。
3. `useFilters`存在时必须是 bool；其它未知 browse字段仍必须抛 `FormatException`。
4. source adapter生成的 browse payload、protocol validator/factory与平台 runtime消费端必须作为同一个跨进程契约验证，不能只在任意三端保持一致。
5. `tool/check.sh`必须执行引入该字段的 dev.171 owner gate与新的 dev.172 protocol gate，使没有 Dart/Flutter SDK的发行环境也能发现字段漂移。
6. Venera不获得 Mihon filter语义；普通 Venera browse只是携带 `useFilters=false`通过共享 wire contract，具体 source业务仍由各自 runtime owner处理。

## 后果

- Venera、Mihon普通 browse恢复，不需要 source-specific兼容代码。
- Mihon filter view继续通过 `useFilters=true`表达；插件默认 `FilterList`语义不回退。
- schema v1旧 request fixture/worker保持可解析，新字段类型和未知字段继续严格验证。
- 将“协议字段漂移”从依赖 Dart单测才能发现的问题提升为 release static gate。
