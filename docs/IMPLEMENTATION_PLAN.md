# zic Implementation Plan

本文件只列未完成工作。

## P0：后台重入设备闭环

- 确认长后台后新 Reader 的首个已使用 texture 不再来自旧 Reader output；只有未使用 prewarm lease 可显示 `textureLeaseReused=true`。
- 检查单串行 blit lane 下 `platformScheduleQueueMicros` 与 `channelDispatchMicros` 不再连续维持 100–230 ms；MethodChannel 必须运行于默认 platform thread。
- 检查前 15 帧 native decode 不再从正常约 52–64 ms 持续退化到约 215–227 ms。
- 检查 `decodeWorkerPlacementStatusCounts`：异构 Android 预期状态 1；dev.133 已使用实际 TID 并与当前 cpuset 求交。状态 2 表示无可用高性能交集，状态 3 表示系统仍拒绝。
- 检查首帧仍满足低性能设备约 400 ms 内目标；后台重入同一 DownloadId 应命中 `artifact-byte-cache`、`deliveryMode=memory-direct`、`chunks=1`，不再出现 17–20 MiB origin session-copy 或 18 段 memory replay。
- 检查 holder-driven playback 缺帧时保持当前 output，恢复后连续播放；新 Trace 中 `decodeStartupDeferredCount` 与 `playbackRebufferCount` 应为 0。
- 检查 current 后续批量 decode 是否减少 worker round-trip 间隙，且 cursor dispose/rewind 无未释放 native frame。

## P0：资源与 partial 回归

- 确认 DownloadSession、artifact、partial source、native priority migration 不受 fresh texture 生命周期影响。
- 确认未封缄 failure 仍进入 source-growth wait，sealed corruption 仍进入有界 recovery。
- 确认旧 `playbackBuffering`/`decode-startup-deferred` 事件不再由新运行时产生；历史 analyzer 指标仅用于比较旧日志。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
