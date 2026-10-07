# dev.275 Venera resolver cache 生命周期审计

## 设备事实

04:42 dev.274 Trace 先确认上一层已经闭合：初始低优先级 local prepare 即使先完成，也被 `deferred-by-higher-local-priority` 阻挡，priority=1000 current 第一个进入 `downloadStarted`。因此本轮不继续修改 partial、local→network admission、NetLane 或 current 数值。

43 次 `firstFrameReady` 的 mount→first-frame 中位约 20 ms、P90约 383 ms，但少数 cold 页仍可达到约 3–4 s。40 次 origin `sourceRead` 中，request-plan cache hit 10 次、miss 30 次：cache hit 的 plan 中位约 0.02 ms，miss 中位约 782 ms。初始 current 的 request-plan 约 2.09 s，bridge network 4/4 均为 origin；warm 后 30 次 miss 中有 27 次表现为 4 个逻辑 `Network.*` 调用中的 3 个 cache hit + 1 个 origin。

这说明当前主问题不是“所有 plan 都必须并行”，而是 source 声明可长时间复用的共享 resolver 结果在 bridge/runtime replacement 后可能重新变冷。

## 源码审计

dev.274 的 `VeneraNativeBridge` 自己持有 `VeneraHttpCache`，并在 bridge `close()` 时 `networkCache.clear()`。这把 source-requested resolver network cache 与 WebView bridge 生命周期绑定。bridge 是请求适配/JS接口 owner，不应同时拥有跨 bridge replacement 有效的 source-network compatibility state。

只读对照 VibeVenera：其 source-requested `NetworkCacheManager` 位于共享 network/AppDio 层，`cache-time: long` 约 6 小时；图片 request-plan 仍按页按需执行，并未依靠整章预解析。因此值得迁移的是 cache owner，而不是复制并发参数。

## dev.275 收口

- `NativeExternalPluginDriverHost` 新持有唯一 `VeneraHttpCacheStore` 并注入所有 Venera driver。
- bridge 使用 `VeneraHttpCacheNamespace(pluginId, pluginVersion, sourceKey)` 隔离 cache；bridge close 不清空，host close 统一清空。
- 保留原 10 MiB/1 MiB 上限、short/long TTL、Cookie/header identity 与 `venera-cache=true` diagnostics。
- `VeneraHttpCacheStore` 的 LRU touch 只在真实 hit 后发生；header mismatch/expired miss 不伪装成使用。
- 不修改 Venera 单 invocation、requestId cancel、NetLane normal5+current reserved1、3/7、5/3/2/1，也不增加 whole-chapter prewarm。

## 后续设备判据

1. 同 plugin/version/source 的 driver replacement 后，原先 `cache-time: long` 的共享 resolver GET 应继续出现 bridge cache hit，而不是重新 4/4 origin。
2. 首次 app/host 生命周期 cold start 仍可 4/4 origin，这是允许的；不要把它误判为 cache owner 回归。
3. 如果共享 resolver 已 warm 且 cold current 仍慢，应继续分别观察 page-specific `sourcePlanRuntimeInvocationMicros` 与 `sourceHostOpenMicros`，不要回头改 partial/NetLane。
