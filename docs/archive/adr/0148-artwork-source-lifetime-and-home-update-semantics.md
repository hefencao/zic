# ADR 0148：Artwork Source 生命周期与 Home 更新语义

- 状态：Accepted
- 版本：0.31.0-dev.165
- 取代：ADR 0025/0028 的 cache-file location/aggregate file-access 决策，以及 ADR 0147 中延续的 durable-file presentation实现；不改变 ADR 0147 的 canonical identity、Home projection 与 runtime generation 决策。

## 背景

设备 trace 出现多张封面先 `homeCoverSourceReady(source=durableCacheFile)`、随后 `homeCoverFirstFrame`，在 Reader 往返后又集中 `homeCoverDecodeFailed`。这类失败发生在已成功首帧之后，不能用 source availability、cache miss或 artwork namespace解释。

代码审计发现 `FileResourceCacheByteStore` 同时拥有 LRU/TTL/invalidate，可删除 cache `.bin`；`ResourceCacheManager` 却把该路径包装成 `FileEncodedResourceSource` 交给 Flutter `FileImage`。presentation 的 ImageProvider 生命周期可以长于 cache entry，因此这是“可撤销文件借用给长生命周期 consumer”的所有权错误。

Home 更新还有独立语义错误：primary projection 在偏好 enrichment 前把缺少 preference 的远程漫画默认当成 `inShelf=true`，且旧更新列表只按通用 metadata `updatedAt` 排序，没有表达“来源确实发现新章节或新版本”。

## 决策

1. response cache 的持久文件永远是 byte-store 私有实现细节。跨 `ResourceCacheManager` artwork 边界只交付拥有自身 `Uint8List` 的 `MemoryEncodedResourceSource`。
2. `FileEncodedResourceSource` 只表示生命周期由 cache 外部保证的稳定本地文件；类型本身固定 `origin=localFile`。删除 file locate/borrow capability，防止重新形成第二生命周期。
3. `SavedComicRecord` 增加可空 `sourceUpdateAt`。它只表示 source-confirmed chapter/version 变化，不复用 `updatedAt`、阅读 progress 或 preference timestamp。
4. 已有非空章节目录基线后，章节 identity/count/sourceRevision/page metadata/publishedAt 变化可推进 `sourceUpdateAt`；第一次建立目录基线不算更新。首次发现新的同源 successor/version同样推进。
5. Home updates 必须同时满足 `inShelf == true` 与 `sourceUpdateAt != null`，并按 `sourceUpdateAt` 排序。远程缺少 preference 时默认不在书架；首次从未入书架变为入书架时清除加入前遗留 signal。
6. 阅读历史继续只消费 `ReadingProgress.updatedAt`，与 update feed 完全独立。

## 后果

- durable artwork warm hit仍无需激活插件，但需要把持久 bytes读入拥有者内存；以少量 warm-read copy换取确定的生命周期安全。
- response cache eviction只影响未来 lookup，不会破坏已经交给 Flutter 的 provider。
- “更新漫画”不再等价于“最近保存/最近阅读”；没有 source变化的书架漫画不会占据更新区。
- 当前没有引入新的后台 source轮询 owner；update signal由既有 source refresh/version discovery路径产生。后续若增加订阅扫描，应写同一个 signal而不是建立第二套 update数据库。
