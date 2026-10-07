# dev.162 Source Resource / Atomic Binding / Catalog Boundary 审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.161_network-user-agent-transport-cache-ownership.zip`。

## 问题清单

### 编译
- `demo_home_source_compat.dart` 仍调用 dev.161 已删除的 `ComicSourceResourceGateway.loadBytes`，导致 App 无法编译。

### 产品/所有权
- `loadPageBytes` 直接调用 `source.loadResource`，与 streaming `pageResponseLoaderFor` 形成两条正文网络路径，绕过 shared host transport/request-plan判断。
- downloads 同时存在 byte-loader 与 streaming-transport 两个独立 setter，可形成只更新一半 capability 的状态。
- `CachedBrowsableComicSource.loadImage/loadImageSource` 与 `loadCachedSourceImage*` 已无生产调用，仅由测试保活，却让 catalog继续表现为第二 artwork owner。

### 性能/阻塞
- full-byte fallback 直接进入 source-owned完整字节能力会绕过 streaming path，增加整页缓冲与错误网络路径重放风险。收口后 full-byte只是在同一 response stream 上收集，不新增并发/缓存 owner。

### 测试
- Venera/source-resource/cache tests仍绑定旧方法名和 split capability；迁移到 atomic access和真正 artwork gateway owner。

## 所有权清单

- `ComicSourceResourceGateway`：App/composition 唯一 raw source resource入口，区分 cached artwork 与 page-body bypass。
- `ExternalPluginResourceTransportPool`：source-resolved host replay/compatibility transport。
- `ChapterResourceAccess`：downloads获得 page byte + streaming能力的唯一原子配置值。
- `ResourceCacheManager`：metadata/artwork response缓存唯一 owner。
- `CachedBrowsableComicSource`：browse/details/chapter metadata decorator，不加载 artwork。
- DownloadSession/artifact/Pipeline：Reader/page body字节与持久 artifact。

## 被否决方案

- 不恢复 `ComicSourceResourceGateway.loadBytes` 通用兼容别名。
- 不保留两个独立 chapter resource setter。
- 不因测试方便保留 catalog artwork facade。
- 不把 page body写入 `ResourceCacheManager`，也不让 artwork走 artifact cache。
- 不从旧版本补入当前基线缺失的 libwebp源码归档。
