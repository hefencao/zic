# dev.166 Retained Artwork Cache 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.165_artwork-lifetime-home-update-semantics.zip`
- 用户反馈：封面 cache 在运行一段时间后被删除本身不正常，应继续结构性收口、解耦。
- `错误报告(20260808-080601).txt`：dev.165删除 file-borrow API时连带删除了 maintenance usage/trim类型，导致 `resource_cache` 与 `storage` 编译失败。

## 根因

1. `FileResourceCacheByteStore.write()` 在每次持久写入后调用 `_trim()`；旧默认持久平面只有 96 项 / 32 MiB。
2. 所有 `imageBytes` 共用这个 LRU/TTL平面：source browse cover、library/history cover、details preview/avatar都没有持久生命周期区别。
3. `ResourceCacheCoordinator.trim()` 还能把持久 response压到24 MiB；因此“运行一段时间后封面文件消失”是旧设计的预期行为，而非单纯 FileImage生命周期 bug。
4. `CachedBrowsableComicSource.invalidateComic()` 使用整个 comic namespace invalidation，详情强制 refresh会把 metadata 与 artwork一起删除，形成第二条与容量无关的封面删除路径。
5. dev.165 为禁止 cache文件路径借用删除接口时，误把与路径无关的 `ResourceCacheByteStoreUsage/TrimReport/Maintenance`纯维护类型一起删除，造成用户报告中的真实编译错误。

## 结构修正

- `ResourceCacheRetention` 与 `ResourceCacheKey` 正交，只有 transient/retained持久生命周期差异，不改变 identity。
- source browse/preview使用 transient；Home/history/details cover请求在相同 key上 promotion为 retained。
- `FileResourceCacheByteStore` 的自动容量 trim、TTL和 maintenance trim只处理 transient；retained记录的 expiry为 null。
- promotion同步写 compact manifest和 per-entry crash-recovery metadata，避免 manifest故障恢复时把 retained错误降级回 transient。
- catalog refresh改为 `invalidateComicMetadata`，明确排除 `imageBytes`；整漫画删除才使用 `invalidateAllComicResources`。
- 恢复纯 maintenance types，旧 `PersistedResourceFile/ResourceCacheByteStoreFileAccess/ResourceCacheFileByteStore/locate()`保持删除。

## 未做

- 没有建立第二个“封面专用缓存目录”。
- 没有增加 presentation retry、watchdog、ImageCache eviction。
- 没有让 retained cover永远驻留内存；内存 response cache仍有界。
- 没有用阅读进度/最近使用时间决定 retained durable cover淘汰。
