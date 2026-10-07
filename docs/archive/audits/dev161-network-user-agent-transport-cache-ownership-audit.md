# dev.161 网络 UA / transport / cache 所有权审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.160_mihon-catalog-venera-runtime-media-fallback.zip`。

## 发现

- 网络默认 UA没有统一 composition owner；通用 transport、章节下载、插件仓库和 source host replay可出现不同 fallback。
- Mihon/Venera request plan可被另一个 Dart HttpClient重放；若发生 redirect、`Set-Cookie`或未知 client wrapper，复制 URL/headers并不能复制 source client状态。
- `ExternalPluginResourceTransportPool`的 raw loader API名称过宽，容易被 metadata/artwork绕过 `ResourceCacheManager`。
- dev.160 Mihon 1.6 `CatalogueSource` shim引入 `kotlinx.coroutines`，但独立 ABI asset generator classpath没有 coroutine库；同时 `lang` override不闭合，导致用户本地 `generateMihonAbiAssets`编译失败。

## 收口

- AppPreferences增加动态 UA fallback，默认 Chrome 150；source/browser UA优先。
- host replay限定为无状态直接媒体响应；redirect/Cookie状态/未知 wrapper/非媒体响应回 source client。
- raw page transport改为 `pageResponseLoaderFor/loadPageBytes`，限定 Reader/章节正文；metadata/artwork仍只走 response cache。
- 新增 direct HTTP/cache bypass白名单 gate。
- Mihon ABI shim移除 coroutine依赖并正确 override `lang`。
