# ADR 0146：正文资源原子绑定与 Catalog Artwork 边界

**状态：Accepted**

## 背景

dev.161 将 raw source transport 与 response-cache bypass 收到 `ComicSourceResourceGateway`，但调用方和兼容 API 未完全迁移：App 仍调用已删除的通用 `loadBytes`；gateway 的 full-byte 实现直接调用 `source.loadResource`，没有复用 streaming host transport；downloads 同时保留 byte-loader/streaming-transport 两个 setter；`CachedBrowsableComicSource` 仍暴露只被测试引用的 artwork facade。它们允许同一资源出现两套网络路径、半更新 capability 或第二 cache owner。

## 决策

1. Reader/章节正文只有 `pageResponseLoaderFor` 与 `loadPageBytes` 两个明确入口；`loadPageBytes` 必须收集同一个 `pageResponseLoaderFor`，不得直接调用 source raw resource capability。
2. Chapter download 的可变来源能力以单一 `ChapterResourceAccess` 原子值绑定；删除 `ConfigurableChapterResourceLoader/Transport` 与对应独立 setter。外部注入 capability 的创建/清理仍由 composition gateway负责。
3. `CachedBrowsableComicSource` 只装饰 browse/details/chapter metadata。删除其 `loadImage/loadImageSource` 以及 `loadCachedSourceImage*` 兼容 facade。external artwork 只能通过 `ComicSourceResourceGateway` + `ResourceCacheManager`；通用 cache key/失效 primitive 可以留在 catalog/cache identity层。
4. page-body bypass不得进入 metadata/artwork；artwork/cached response不得进入 DownloadSession/artifact平面。
5. 不恢复通用 `loadBytes` 别名来兼容旧调用方；调用方必须选择 page-body或 cached artwork语义。

## 结果

网络请求资格、cache bypass资格和 capability生命周期现在由 API 名称与类型共同约束，避免 presentation/catalog/tests 重新获得 raw transport捷径。
