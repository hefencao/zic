# zic Implementation Plan

本文件只列未完成工作。

## P0：后台重入设备闭环

- 确认长后台后新 Reader 的首个已使用 texture 不再来自旧 Reader output；只有未使用 prewarm lease 可显示 `textureLeaseReused=true`。
- 检查 `textureLeaseReusedBridgeOver100msCount` 不再持续增长，bridge/schedule 不再连续维持 100–230 ms。
- 检查前 15 帧 native decode 不再从正常约 52–64 ms 持续退化到约 215–227 ms。
- 检查 `decodeWorkerPlacementStatusCounts`：异构 Android 预期状态 1；状态 2 表示无异构 mask/探测不可用，状态 3 表示系统拒绝。
- 检查首帧仍满足低性能设备约 400 ms 内目标，且后续播放不以旧 texture 恢复换取首帧。

## P0：资源与 partial 回归

- 确认 DownloadSession、artifact、partial source、native priority migration 不受 fresh texture 生命周期影响。
- 确认未封缄 failure 仍进入 source-growth wait，sealed corruption 仍进入有界 recovery。
- 检查 `playbackBufferingOutstandingCount=0`、`playbackRebufferCount=0`；被 startup gate 暂缓的页面应出现 `decodeStartupDeferredCount`，之后升为 current 必须完成首帧。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
