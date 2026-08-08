# ADR 0149：Retained Artwork 持久生命周期与失效边界

- 状态：Accepted
- 版本：0.31.0-dev.166
- 取代：ADR 0148 中“只要 presentation 自持有 bytes，即允许 durable artwork继续按普通 response LRU/TTL删除”的隐含假设。

## 背景

dev.165 已禁止把 response-cache 管理的 `.bin` 路径借给 `FileImage`，因此 cache 删除后不会再制造悬空文件路径。但继续审计发现，封面文件被删除本身不是异常偶发事件，而是旧 persistence policy 的正常结果：`FileResourceCacheByteStore.write()` 每次写入都执行一个 96 项 / 32 MiB 的 LRU trim，并对全部 `imageBytes` 使用同一 TTL；统一 maintenance 还允许把持久 response 压到目标容量。source browse、preview/avatar 与已经成为 library/history 状态一部分的 cover 因而处于同一个回收平面。

这违反“缓存 owner统一”并不意味着“所有资源拥有同一生命周期”的原则。封面 canonical identity已经稳定，但持久生命周期仍被临时浏览流量决定。

## 决策

### 1. Identity 与 retention 正交

`ResourceCacheKey(kind + identity + namespace + revision)` 继续是唯一 cache identity。新增 `ResourceCacheRetention.transient/retained` 只表达持久生命周期，不参与 equality/hash，也不得产生第二 namespace。

同一条 artwork 可以先由 source browse作为 transient写入，之后被 library/history/details使用时原地 promotion 为 retained。

### 2. 两个持久生命周期仍属于同一个 cache owner

- `transient`：适用于 source browse、preview、avatar等可重新获取的临时 artwork；受 TTL、transient LRU容量和 maintenance target约束。
- `retained`：适用于已经进入 library/history/details持久语义的 cover；不受运行期容量/TTL整理。删除只来自精确 artwork revision/force invalidation、整漫画资源显式删除或用户清缓存。

这不是第二个 cache backend。两类记录继续位于同一个 `FileResourceCacheByteStore`、同一个 manifest、同一个 key空间中。

### 3. Memory 与 durable 生命周期分离

内存 response plane仍保持有界，retained cover可以从内存 LRU退出；需要再次展示时从 durable bytes恢复。presentation取得的 encoded bytes继续自持有，不依赖 durable文件后续存在。

### 4. Metadata invalidation 不能连坐 artwork

`CachedBrowsableComicSource` 的 details/chapter刷新只允许失效 metadata kinds。禁止通过 `invalidateNamespace(comic)` 粗粒度删除 artwork。整漫画删除是单独的 `invalidateAllComicResources` 生命周期动作。

### 5. Maintenance contract 与文件借用 contract 分离

dev.165 误把 `ResourceCacheByteStoreUsage/TrimReport/Maintenance` 与已否决的 file-locate接口一起删除。前者是纯维护能力，必须存在；后者泄漏 cache-owned文件路径，继续禁止。

`trimPersistentBytesTo()` 的目标只计算/淘汰 transient bytes；inspect同时报告 total 与 retained子集。

## 结果

- 普通 browse/preview压力不能删除书架/历史封面。
- retained cover不会因为应用运行时间、LRU写入次数或普通 maintenance自动过期。
- metadata刷新与 artwork生命周期解耦。
- 不引入第二个 artwork cache、第二 namespace或 presentation retry。
- retained集合的空间增长由 library/history可达性、显式漫画删除和用户清缓存管理；后续若需要自动垃圾回收，必须基于 durable owner reachability，而不能退回全局 LRU。
