# ADR 0322：统一 presentation raster cache authority

## 状态
Accepted。

## 问题

2026-09-24 真机 `zic-debug-trace-2026-09-24T04-09-58.jsonl` 证明，external-static detached warm 本身已正常完成，presentation file lease p95 约 22.8ms，但 page15/18/22/23 仍在成为 current 后约 230/739/690/311ms 才首帧。挂载时旧 trace 明确显示这些 provider 已从 Flutter 全局 `ImageCache` 被淘汰；相邻仍 tracked/keepAlive 的页则同步命中。

问题不是 warm 数量不足，也不是需要扩大 3/7 或 100MiB：Pipeline 把“某时刻 warm 成功”错误升级成了长期 residency proof，而 raster 实际仍由另一套黑盒 LRU 决定。`obtainCacheStatus()` 只能事后查询，无法形成所有权闭环。

## 决策

1. App composition 的 `PipelinePresentationRasterCache` 是 Reader external-static raster 的唯一 residency/LRU authority。mounted `MediaRasterImage` 与 detached prewarmer 必须在 exact fit/raster key 计算后进入同一个 manager。
2. manager 保留同一个 `ImageStreamCompleter.keepAlive()` handle，不复制 RGBA。admission 后移除该 provider 在 generic Flutter `ImageCache` 中的 keepAlive entry，并按 manager 实际 bytes/entries 动态缩减 generic ImageCache 剩余额度；两层共享一个 100MiB/1000-entry presentation envelope，而不是两个 100MiB cache。
3. Pipeline 只表达 residency claim：`far/detached=speculative`，`next2/next/previous/near/last=deadline`，真实 viewport/current/transition=`protected`。manager 只在预算压力下回收 speculative entry；deadline/protected 不可被 speculative LRU 挤掉。
4. manager 真实回收时主动按 `presentationIdentity` 通知 Pipeline。Pipeline 撤销 `externalPresentationSatisfied`，由既有 `StagedDecodeRefillPolicy` 在需求有效时补帧；不得由 `LocalImagePlayer`/Pipeline 轮询 `ImageCache.statusForKey` 或 `ImageProvider.obtainCacheStatus`。
5. eviction 只改变 residency，不改变 presentation generation。普通 demand gap、role migration、Reader route retention/reentry 都不得旋转 `externalPresentationCacheIdentity`；source/recovery/force-reload、DecodeId raster target 或 typed fit 变化才是 generation boundary。
6. `ResourceCacheCoordinator.presentationRasters` 统一纳入 inspect/trim/clear。该 volatile presentation plane 单独报告，不冒充 durable user cache bytes；设置页/内存压力不得绕过 coordinator 建第二维护入口。

## 边界

native decoded/upload surface 仍归 `FrameBudgeter`；encoded durable/hot bytes 仍归 ArtifactCache/physical transfer owners；`PipelinePresentationRasterCache` 不选择下载、decode 或 warm 资格。3/7 intent、staged refill、speculative encoded budget 与 idle warm 均保持原有职责。

## 验收

- managed raster owner 不读取 Flutter `ImageCache` liveness 来决定 eviction；
- far raster 可被主动回收且不会立即形成 eviction/redecode 环；
- 同 identity 进入 deadline role 时 claim 主动升级，若 residency 已丢失则沿既有 staged grant 补帧；
- eviction 后再次 warm 必须复用同一个 presentation generation identity；
- mounted 与 detached 路径必须复用同一 completer/key；
- ResourceCacheCoordinator 的 inspect/trim/clear 能覆盖 presentation raster plane。
