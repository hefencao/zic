# ADR 0119：Catalog Cache Weight 与无调用兼容层清理

**状态：Accepted**

## 背景

dev.135 将目录、详情和章节元数据接入统一 `ResourceCacheManager` 分类预算，但 `CachedBrowsableComicSource` 引用了未定义的 `_browseWeight`、`_comicWeight`、`_chapterWeight`，导致 Dart 编译失败。仓库还保留了一组仅有声明或静态门禁引用的 local WebP-folder / App local-image compatibility facade。

附带旧日志还包含 Artifact backend、prewarmer、scheduler、ingress 和 frame timing API 错误；这些接口在 dev.135 当前基线中已经闭合，不能以旧日志为理由恢复被取代的 facade。

## 决策

1. metadata value 的结构估算由理解领域结构的 `catalog/CachedBrowsableComicSource` 所有。
2. weight 计算覆盖字符串、URI、集合和嵌套 manifest 对象，使用近似 byte weight；不固定为 1，不 JSON encode 整个对象。
3. 容量、TTL、LRU、分类预算和 in-flight join 仍由唯一 `ResourceCacheManager` 所有。
4. Reader page bytes 不进入 metadata response cache，继续由 `ArtifactCacheManager` / downloads / sessions / pipeline 所有。
5. `PromotedArtifactCacheHandoff` 的提交错误边界使用显式 `Future<void>` async owner，不使用运行时可能违反 Future 返回类型的无返回值 `catchError`。
6. 删除全仓无生产/测试 import 的 `local_webp_folder.dart`、`local_image_folder.dart` 和旧 WebP-folder typedef/model/screen/picker/key alias。
7. 保留仍有生产或测试调用的 App `reader_runtime.dart`、`media_load_token.dart`，以及单文件 WebP、ImageFolder 当前 API。
8. 删除前必须全仓引用检查；门禁禁止已删除兼容符号回流。

## 后果

- 大型搜索结果、详情和章节页清单按规模占用 response-cache budget。
- App 不再暴露无调用的兼容入口，文件夹导入直接依赖拥有实现的 package。
- 旧外部调用若依赖未使用的 App facade，需要迁移到 `local_media` / `local_media_ui`；仓库内没有此类调用。
- 不改变 Reader、下载、插件、network 或 native ABI。
