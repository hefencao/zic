# ADR 0070: 共享网络桥与插件协议适配分离

## Status

Accepted for `0.31.0-dev.86`.

## Context

dev.85 为 Mihon Cloudflare 恢复在 `plugin_host_bridge` 中加入了通用 WebView、Cookie snapshot、CookieJar、Cloudflare interceptor 和 DNS fallback。随后 Dart 编译暴露出详情 callback typedef 漏提交，同时所有权审查确认这些能力也会被原生来源、未来 native 插件或其他 HTTP backend 使用，不应由插件隔离桥垄断。`transport` 已拥有正文请求/响应与 range 语义，因此也不能再建立一套独立下载平面。

## Decision

1. 新建 `network_bridge`，拥有 Android 来源浏览器、Cookie/localStorage snapshot、Android CookieJar、Cloudflare challenge interceptor 与 fallback DNS。
2. `plugin_host_bridge` 依赖该 package，但只保留插件信任、隔离、ABI/protocol adapter、request routing、取消和生命周期。
3. Mihon 1.4/1.6 `NetworkHelper` 保留上游兼容包名，内部改为消费 `dev.zic.network`。动态 classloader 对共享类使用 parent-first，并在 activation 前验证类存在。
4. network bridge 将共享 runtime helper 编译进 Android library，并发布 consumer keep rules；Mihon ABI 资产构建仍从同一 owner 源编译兼容外壳，避免复制另一份实现源码。
5. App composition 直接持有并注入 `AndroidNetworkBridge`；详情 Presentation 只消费 `ComicDetailsSourceWebViewOpener` callback。`ExternalPluginController` 不暴露或转发通用网页登录/Cookie API。
6. `NetworkBrowserActivity` 的 Android 进程名使用 manifest placeholder，由 App composition 决定。当前 App 选择既有隔离 WebView 进程以共享 WebView/Cookie profile；network package 不硬编码 plugin process。
7. 浏览器 snapshot 通过 App 私有目录中的临时文件写入和原子 rename 跨进程交接；禁止使用 SharedPreferences 作为跨进程权威状态。
8. rhttp 未在本轮引入。未来 rhttp/其他 native HTTP client 必须作为共享 transport/network backend 由 composition 注入，复用稳定 identity、DownloadSession、artifact 和 Pipeline。

## Consequences

- 原生来源和插件 adapter 可复用同一 Android 网络能力，而无需依赖 plugin host。
- `plugin_host_bridge` 不再拥有通用登录 Activity、snapshot store 或 Cloudflare/CookieJar/DNS 实现。
- Mihon ABI 仍兼容上游扩展，但共享网络类的 release shrink 和 classloader 完整性成为显式契约。
- 浏览器进程策略成为 composition 值；登录 snapshot 不再受 SharedPreferences 跨进程缓存影响。
- Venera restricted WebView 和 JavaScript `Network` API 仍是协议特定 adapter；它不能成为通用网络 owner。
- 需要 Flutter/Android 工具链和真机继续验证多进程 WebView/Cookie 行为。

## Rejected alternatives

- 只补 typedef，而继续让 plugin host 拥有所有通用网络能力。
- 把 Cloudflare/Cookie/rhttp 放进 App 页面、Reader 或来源 UI。
- 为原生来源复制一套 Cloudflare/Cookie helper。
- 让 rhttp 绕过 transport、DownloadSession 或 artifact 直接向 Reader 返回字节。
- 将插件协议适配器迁进通用 network package，反向污染其依赖方向。
- 在 network package manifest 中硬编码 `:zic_plugin_runtime`，或用 SharedPreferences 充当跨进程 snapshot。
