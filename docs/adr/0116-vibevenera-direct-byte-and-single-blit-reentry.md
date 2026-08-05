# ADR 0116：VibeVenera 直接热字节与单 Blit 后台重入

> dev.134 注：本文的 affinity/cpuset 决策及“memory hit 重灌新 DownloadSession”的路径已由 ADR 0117 取代；单 platform channel/单 blit lane 决策仍有效。


**状态：Accepted in dev.133**

## 背景

dev.132 仅迁移了 holder producer/consumer。设备 Trace `zic-debug-trace-2026-08-05T02-01-59.jsonl` 仍显示：长后台后 current 页面可能因 4 项/96 MiB 热缓存被 7/3 邻页淘汰而重新读取 18 MiB `content://`；即使命中 `artifact-byte-cache`，正文仍按 1 MiB 分成 18 段回放，耗时约 971 ms。Android output 仍使用 background MethodChannel、两个 blit lane 与 `postAtFrontOfQueue`，而 VibeVenera 使用默认 platform channel、单串行 blit executor 和普通主线程 `post`。同一 Trace 的 `workerPlacementStatus` 全部为 3，说明旧 affinity 请求被目标设备拒绝。

## 决策

1. `ArtifactCacheManager` 默认热字节窗口改为 10 项、256 MiB；缓存仍由 composition 统一所有，不进入 Reader/App。
2. 完整本地不可变 origin 记为进程内 durable immutable；current 的 memory hit 以单个 `Uint8List` body 进入既有 DownloadSession/native ingress，不再进行 1 MiB cooperative replay。持久 artifact 首次 read-all 仍保留 startup segmented 交付。
3. Android texture MethodChannel 使用默认 platform thread；所有 output 共用一个串行 blit lane；native blit 后通过普通 `mainHandler.post` 执行 `scheduleFrame` 和结果回调。删除 background task queue、双 lane 与 `postAtFrontOfQueue`。
4. Android decode worker affinity 使用实际 TID；先读取当前 `sched_getaffinity` mask，并与高性能核心 mask 求交，再调用 `sched_setaffinity`。成功后按 VibeVenera best-effort 请求 `nice=-10`，失败不影响解码。
5. native ABI 号不变，library build identity 更新为 `zic-media-core-dev133-abi6-lib00121300`。

## 所有权

- 热字节/LRU：`downloads/ArtifactCacheManager`。
- DownloadSession、native ingress、artifact 状态：`sessions/downloads`。
- texture/SurfaceProducer/blit lane：Android `texture_bridge`。
- decode worker placement：`native/media_core`，由 `bridge` 进程常驻 worker 调用。
- Reader 只消费 Pipeline output，不持有正文、texture、executor 或 affinity。

## 拒绝方案

- 不恢复跨 Reader used texture。
- 不扩大 decode worker 数量。
- 不再次添加 startup-buffer gate。
- 不把 18 MiB memory hit 重新切成小块以换取表面上的 event-loop cooperative。
- 不在 App/Reader 建第二套 ByteCache。

## 验收

后台重入同一 DownloadId 应记录 `artifact-byte-cache`、`deliveryMode=memory-direct`、`chunks=1`；不再读取相同 `content://` origin。Android output 不包含 background task queue、双 blit lane 或 front-of-queue schedule。异构设备应优先出现 `workerPlacementStatus=1`；若仍为 3，需要记录实际 errno/厂商限制再处理。
