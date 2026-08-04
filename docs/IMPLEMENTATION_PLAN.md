# zic Implementation Plan

本文件只列未完成工作。

## P0：启动缓冲闭环设备验证

- 确认每个 `playbackBuffering waiting` 都对应一个 `ready`；
-确认 current 按目标需要连续执行 `c>2/c>4/c>6`，而非停在 depth 3；
-确认 `playbackBufferingOutstandingCount=0`；
-确认 ready 后 next/next+1 refill 恢复，切页前首帧预解码不再被长期阻塞。

## P0：动画节奏设备闭环

- 对齐 nominal duration 与 visible interval；
-检查 deadline lead、native decode 和 platform present 是否仍产生持续停顿；
-不通过降低播放速度或扩大长期缓存掩盖。

## P0：后台与 partial 回归

继续验证 retained output 恢复、source-growth wait 与 authoritative frame 替换。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
