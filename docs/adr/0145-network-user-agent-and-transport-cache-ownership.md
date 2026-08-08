# ADR 0145：网络默认 User-Agent 与 transport/cache 所有权

**状态：Accepted**

## 背景

dev.160之后仍存在两类旁路风险：一是多个 Dart/Kotlin网络 owner可以自行选择 User-Agent，shared source transport甚至曾使用来源无关的默认 UA；二是 raw transport API命名过于泛化，metadata/artwork调用方可以绕过 `ResourceCacheManager`。与此同时 Mihon/Venera拥有自己的 client wrapper、CookieJar/interceptor/session语义，宿主简单重放 URL/headers并不总等价。

## 决策

1. 网络默认 User-Agent由 AppPreferences/composition拥有，默认 Android Chrome 150；通过动态 provider注入通用 transport、Reader/章节 fallback、插件 control-plane与 shared source host transport。source显式 UA和 browser-session UA优先。
2. Presentation不得创建独立 HTTP client。生产 direct-network owner采用显式白名单：通用 transport、source-resolved host replay、source-owned runtime/client、插件安装 control-plane与网络基础设施。
3. source host replay只处理可无状态平铺的单请求：不自动跟随 redirect；若响应 redirect、设置 Cookie、返回非媒体内容，或 source client存在未知 wrapper，则直接切回 source-owned client。独立 host client不得成为来源 Cookie/session长期权威。
4. `ResourceCacheManager`唯一拥有可重复获取的 metadata/artwork response cache。raw source transport只由 `ComicSourceResourceGateway`构造。Reader/章节 page body由 DownloadSession/artifact/Pipeline拥有，使用明确命名的 `pageResponseLoaderFor/loadPageBytes`绕过 response cache。
5. 插件仓库/APK/JS下载属于 control-plane，不进入漫画 response cache，但复用 composition UA fallback。
6. Mihon 1.6 ABI shim不得依赖 host asset generator未提供的 coroutine库；兼容层保持自包含 classpath。

## 后果

- 用户可在一个设置中调整默认 UA，而不会覆盖 source/browser自己的权威 UA。
- 新增裸 HTTP或 raw transport调用会被 ownership gate拒绝。
- 需要 Cookie/interceptor/session的 source请求不会被“复制 headers后另发一次”的独立 client悄悄接管。
- 当前 source-owned runtime兼容路径仍可能整块返回 `Uint8List`；未来若要彻底消除 host replay seam，应设计 binary stream/file lease接入统一 Pipeline，而不是恢复完整正文 JSON/Base64 RPC。
