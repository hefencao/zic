# zic Implementation Plan

本文件只列未完成工作。

## P0：启动播放节奏设备闭环

- 确认 `playbackBuffering` 依次出现 waiting/ready；
- 对齐 nominal frame duration 与实际 visible interval；
- 验证首帧仍快速显示、缓冲期间 next demand 未删除、ready 后邻页 refill 恢复；
- 检查 `playbackLeadMicros` 是否降低 deadline miss，且没有提前跳帧。

## P0：低性能设备 native decode

若 deadline lead 和启动缓冲后 cadence 仍不足，继续分析 worker dispatch/native decode，不通过降低帧率或扩大长期缓存掩盖。

## P0：后台与 partial 回归

继续验证 retained output 恢复、source-growth wait 与 authoritative frame 替换。

## P1：纵向 build/layout

继续用设备 Timeline 验证稳定 page composition 与渐进 host warm 的实际收益。
