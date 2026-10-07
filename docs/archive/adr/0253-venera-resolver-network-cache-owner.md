# ADR 0253：Venera resolver Network cache 归属 native driver host

- 状态：Accepted
- 日期：2026-08-14

## 背景

Venera source-requested `Network.*` 支持 `cache-time`，其中 `long` 约为 6 小时。此前缓存对象由每个 `VeneraNativeBridge` 自行创建并在 bridge `close()` 时清空，因此缓存寿命被错误绑定到 WebView/driver bridge 实例。bridge replacement 会让仍在 source 声明有效期内的 resolver GET 再次冷启动。04:42 真机 Trace 同时证明 dev.274 local→network priority continuity 已成立，剩余 cold tail 主要位于 Venera request-plan/runtime/host-open；warm resolver miss 通常已表现为共享 resolver 命中后仅剩 page-specific origin，因此不需要预解析整章或增加 JavaScript 并发。

## 决策

1. Venera source-requested resolver cache 的生命周期 owner 为 `NativeExternalPluginDriverHost`，不是单个 `VeneraNativeBridge`。
2. host 持有唯一 `VeneraHttpCacheStore`，同 host 生命周期内创建/替换的 Venera driver/bridge 复用该 store。
3. cache key 由类型化 `VeneraHttpCacheNamespace(pluginId, pluginVersion, sourceKey)` 与 URL 组成。插件版本或 sourceKey 改变必须自然隔离，不允许跨 namespace 命中。
4. bridge 只消费 cache，不拥有或清空它；driver/bridge close 不得使同 namespace 的 `cache-time: long` 失效。host 最终 close 时统一清空。
5. 保留既有全局 10 MiB cache 上限、单项 1 MiB 上限、约 5 秒短 TTL 与约 6 小时 long TTL。迁移 owner 不增加第二份 cache，也不把 resolver response 持久化到 Reader/artifact cache。
6. Cookie/request-header identity 规则保持；header 不匹配不得命中。`cache-time`/`prevent-parallel` 继续只作为 runtime control fields，不发送给 origin。
7. Venera JavaScript `maxConcurrentInvocations=1` 保持。不得用增加 JS 并发、整章 request-plan prewarm 或 Reader/Pipeline cache 代替该生命周期修复。

## 结果

- 同 source/plugin version 的 bridge replacement 不再机械丢失 source 声明的 long resolver cache。
- 首次真正 cold resolver 仍可能访问 origin，page-specific POST/动态解析仍属于 source request-plan 工作；本 ADR 不宣称消除首次冷启动。
- `VeneraNativeBridge` 回到 adapter/bridge owner，resolver network compatibility state 回到 runtime-network composition owner。
