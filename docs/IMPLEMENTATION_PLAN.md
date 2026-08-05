# zic Implementation Plan

本文件只列未完成工作。

## P0：Native Decode Priority Migration 设备闭环

- 确认页面由 far/next 升为 current 时出现 `decodePriorityPromoted`；
- 确认 queued promotion 后，同 identity 很快出现 `frameDecoded frame=0`；
- 确认 source 已 ready 的 current 不再整个 host 生命周期保持 `firstFrameReady=false`；
- 确认 retained output current 在 authoritative successor ready 后恢复播放；
- 确认 active promotion 最多等待当前一次 native call，不产生 cursor 重建或 duplicate decode。

## P0：动画播放与加载回归

- 检查 `playbackBufferingOutstandingCount=0`；
- 检查 current ready 后 next/next+1 refill 正常恢复；
- 不通过增加 worker、扩大长期缓存或 visible demand 掩盖优先级问题。

## P0：后台与 partial 回归

继续验证 retained output 恢复、source-growth wait 与 authoritative frame 替换。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
