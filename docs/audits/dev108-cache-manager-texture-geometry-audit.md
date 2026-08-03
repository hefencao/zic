# dev.108 Reader artifact cache 与 native texture 审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.107_reader-reentry-progressive-artifact-handoff.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-03T14-04-54.jsonl`。
- 参考实现：VibeVenera 当前文件缓存与 Android texture blit。

## 结论

### 缓存架构

用户的质疑成立。dev.107 的 `ArtifactCachePresenceStore` 是补丁式 capability：memory 与 persistent chapter service 分别回答 presence，而 transport、hot-byte cache 和 handoff 仍各自分派。它没有形成一个真正的多级 cache router。

正确边界不是把所有缓存合并进一个全局类，而是在 Reader page-artifact 域建立中央 manager：

- 统一 `DownloadId + length` 判断；
- memory→persistent backend 查找；
- 并发 read-all 合并；
- encoded-byte LRU；
- 读取可见性与 backend 持久存在性分离；
- invalidate 和 write-through；
- backend 只保留存储原语。

普通 response cache 保持独立，因为 TTL/请求语义与 partial/resume/promotion 不同。

### 设备性能

- 261 条 `framePipelineTiming` 全部为 `flutterFallback`。
- 464 条 task failure 中，461 条是 `native blit failed with status 4`，并回退 `flutterImage`。
- 第三次 Reader 已出现真实 memory cache hit，artifact materialize 仅数微秒，但 session-copy 仍约 0.7 秒，播放仍 fallback。
- 因此 dev.107 的缓存命中有效但不是主要播放卡顿根因；native texture lock failure 使每帧走 Flutter fallback decode。
- Reader 2 dispose 仍约 5.2 秒，主要位于 coordinator；新 Reader 在旧 dispose 尚未完成时创建。

## 修改

| 问题 | 所有者 | 修改 |
|---|---|---|
| tier/presence 分散 | `downloads` | 新增 composition `ArtifactCacheManager` |
| backend 复制策略 | chapter services | 改为 `ArtifactCacheBackend` 存储原语 |
| cache lookup materialize 持久 session | persistent backend | 直接按 durable index/path 打开 ready artifact |
| transport/handoff 路由不一致 | `downloads` | 共享同一个 manager |
| queued task 未被 registry snapshot 取消 | `sessions` | lane `cancelAll()` |
| native blit lock status 4 | `texture_bridge` / native | 生命周期边界 geometry + 一次重试 |
| Trace 无 configure/retry | texture telemetry | 新增 configure 与 retry 字段 |

## 删除

- `ArtifactCachePresenceStore`。
- `PromotedArtifactReadPool` 及其测试；完整读取合并由中央 manager 的 memory tier 负责。
- transport、handoff 和 pipeline factory 中独立的 hot cache/read-pool 分派。

## 未验证

本轮环境没有 Flutter/Android 设备工具链。geometry 修复、platform path 恢复、首次进入和重进性能必须由 dev.108 设备 Trace 验证。
