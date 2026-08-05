# zic Implementation Plan

本文件只列未完成工作。

## P0：目标页首帧设备闭环

- 验证拖动建立 transition 后，即使 current depth 为 0，也会出现 `decodeRefill stage=t>0`。
- 验证目标页首帧不等待 current source sealed、完整下载或 depth 3。
- 确认新 Trace 不再出现 `downloadFlowPressure`；不得以其他名称重建 holder-depth 网络资格门控。
- 验证 transition 首帧后 current `c>2` 先于 transition 深水位，避免反向饿死 current。

## P0：远程 WebP 连续性

- 继续观察 transport chunk 合并后的 `bytesCommitted.chunks`、source growth 与 frame cadence。
- 若 current 仍断粮，只在 NetLane ranking、重复 transport/source 或 producer wake 内查因；不得冻结 target transport、缩小 7/3 或降低播放速度。

## P0：Flutter 编译与 owner tests

- 运行 `flutter analyze`、sessions decode-refill tests、Reader/Pipeline tests 和 App target tests。

## P1：首页与缓存身份

- 继续验证首页 primary/enrichment、dev.135 stable cover/artifact identity 和 dev.134 同章资源会话 retention。
