# ADR 0092：Reader artifact 统一路由与 Android Surface 几何配置

**状态：Provisional**

## 问题

dev.107 仍存在两个相互独立的问题：

1. Reader page artifact 的热字节、持久 artifact、transport 命中和 handoff presence 分散在多个对象中。memory 与 persistent chapter service 都实现 presence，只能减少某一条重复写入，不能保证 key 规范、tier 顺序、并发读取合并、长度校验和失效策略一致。
2. 设备 Trace 中三个 Reader 会话的全部逐帧样本都走 `flutterFallback`，并出现大量 `native blit failed with status 4`。缓存命中后仍卡顿，说明 Android native texture 已退出主播放路径。ZIC 在 dev.96 删除了 `ANativeWindow_setBuffersGeometry`，随后直接 lock Surface；VibeVenera 仅在首次、尺寸变化或 Surface 重建时配置 geometry。

## 方案评估

### 各 backend 自行实现 presence / tier 判断

优点：接口小、局部改动少。

缺点：key、长度和 tier 顺序会漂移；transport、handoff 与快速重进可能得到不同结论；新增 backend 必须复制策略。拒绝。

### 将 Reader artifact 合并进通用 response cache

优点：表面上只有一个 cache coordinator。

缺点：response cache 的 TTL/LRU/请求语义与 Reader artifact 的 partial、resume、seal、promotion、active writer 和大文件语义不同；会把可恢复下载与普通响应缓存耦合。拒绝。

### Reader artifact 域内中央 manager，存储 backend 可替换

优点：一个对象统一规范化 key、memory→backend 查找、读取可见性、backend 持久存在性、长度校验、并发整文件读取合并、热字节 LRU和写穿；Memory/Persistent chapter service 只提供存储原语，便于测试和平台替换。

代价：manager 必须保持 composition 生命周期，并明确不能成为第二个 DownloadSession、partial writer 或播放策略所有者。选择。

## 决策

1. `downloads.ArtifactCacheManager` 是 Reader page-artifact 域唯一 tier router。它拥有 encoded-byte memory tier，并组合一个 `ArtifactCacheBackend`。
2. `ArtifactCacheBackend` 只提供 immutable promoted artifact 的 open/read/store 原语。Memory 与 Persistent chapter service 是替代 backend，不再分别实现 presence 策略。Persistent backend 从 durable index/path 直接解析 ready artifact，cache lookup 不得仅为读取而 materialize `DownloadSession`。
3. `ArtifactCacheTransport`、`PromotedArtifactCacheHandoff`、Reader 快速重进和 presentation bytes loader 必须共享同一个 composition manager。读取可见性可命中任意 tier；handoff 的 durable write-through 只能由 manager 的 backend-presence 判断，L1 memory hit 不得伪装成已持久化。
4. 通用 `ResourceCacheCoordinator` 继续管理普通响应缓存，不接管 Reader partial/promotion 生命周期。
5. Android texture 在 output 首次创建、真实 resize、Surface available/cleanup 后设置 `needsConfiguration`。blit 前仅在该状态调用 `ANativeWindow_setBuffersGeometry`。
6. 若 `ANativeWindow_lock` 返回 status 4，只允许重新配置并重试一次；禁止每帧设置 geometry。
7. native texture 失败仍可回退 Flutter image，但 Trace 必须记录 configure 耗时、重试次数和 fallback，不能把 fallback 性能归因给缓存。
8. Reader dispose 使用 lane-level `cancelAll()`，清除 active 与 pending task，避免 registry snapshot 遗漏尚未建 session 的 queued key。

## 所有权

- `downloads`：Reader artifact key/tier 路由、hot bytes、backend、handoff。
- `pipeline_runtime`：composition manager 注入和 Reader lifecycle。
- `storage` / chapter backend：partial、seal、promotion、持久存储原语。
- `texture_bridge` + `native/media_core`：SurfaceProducer、geometry、native blit、schedule。
- Reader/App 不拥有缓存策略、下载 session、texture buffer 或 native frame。

## 解除 Provisional 条件

设备 Trace 证明：

- current 快速重进出现中央 manager memory tier 命中；
- 不再出现 backend-specific presence 分派；
- platform presentation 恢复，`flutterFallback` 不再覆盖全部帧；
- geometry 只在首次/重建/resize 或一次 lock retry 发生；
- `blit_failed status 4` 不再持续出现；
- 首次进入与快速重进的首帧、前 12 帧和 dispose 重叠得到改善。
