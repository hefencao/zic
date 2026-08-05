# dev.136 编译闭包与废弃代码审计

## 唯一基线

`zic_v0.31.0-dev.135_unified-version-stable-cache-identity-reuse.zip`

## 问题清单

### 编译错误

- `CachedBrowsableComicSource` 已向 `ResourceCacheManager.getOrLoad` 传入 `_browseWeight`、`_comicWeight`、`_chapterWeight`，但三个私有函数未定义。
- 附带旧日志中的 `ArtifactCacheBackend.invalidateArtifact`、`PipelineOutputPrewarmer` 类型收窄、nullable `ArtifactCacheReadScheduler`、`EncodedSource.reserveExpectedLength` 和 Frame timing capability 在 dev.135 基线中均已有当前接口，不应为旧日志恢复兼容 facade。

### 产品错误

- 本轮没有新增产品行为修改。metadata response cache 仍只缓存目录/详情/章节元数据，不缓存 Reader 页面正文。

### 性能问题

- 若 metadata cache weight 退化为固定常量，分类预算无法反映大型搜索结果、章节页清单和详情文本，可能挤占全局 response cache。

### 测试错误

- dev.135 的三个 App quarantine 已使用 `skip: true` 和登记注释；不恢复字符串型 `skip`。
- 冷 Reader artifact 测试的异步错误应由拥有 Future 的生产清理路径或可控 test harness 处理，不使用无返回值 `catchError`。

## 所有权清单

- metadata value weight：`catalog/CachedBrowsableComicSource`，因为它理解 `SourceBrowsePage`、`ComicManifest`、`ChapterManifest` 的结构。
- 容量、TTL、LRU 和 in-flight join：唯一 `resource_cache/ResourceCacheManager`。
- Reader artifact：唯一 composition-owned `downloads/ArtifactCacheManager`；不进入 metadata weight 估算。
- 本地文件夹导入：`local_media` + `local_media_ui` 的 ImageFolder API；App 旧 WebP-folder facade 无生产调用。
- 单文件 WebP preview：`local_media_ui`，继续保留 `PickedWebp`、`WebpPicker`、`WebpPlayerScreen` 和 `WebpBytesLoader`。

## 被否决方案

- 不把三个 metadata weight 简化为固定 `1`。
- 不通过 JSON encode 整个 manifest 计算 weight，避免额外分配和语义耦合。
- 不恢复已被当前接口替代的 Artifact/Prewarmer/Ingress 兼容层。
- 不保留只剩声明的 WebP-folder typedef、wrapper screen、key alias 和 App facade。
- 不删除仍有生产调用的单文件 WebP API。

## 删除候选的全仓引用结论

以下符号除声明自身外无引用，可直接删除：

- `apps/app/lib/local_webp_folder.dart` 全文件；
- `apps/app/lib/local_image_folder.dart` 全文件（仅剩静态门禁和历史 ADR 引用）；
- `localWebpFolderImportKey`；
- `localWebpFolderPickerProgressKey`；
- `WebpFolderPicker`；
- `PickedWebpFolder`；
- `webpFolderScreenKey`；
- `pickLocalWebpFolder`；
- `defaultWebpFolderPicker`；
- `WebpFolderScreen`。

`WebpLoadToken` 只有 package 内部调用和静态门禁引用，迁移为直接使用 `MediaLoadToken` 后删除。
