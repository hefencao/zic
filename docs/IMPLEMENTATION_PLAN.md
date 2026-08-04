# zic Implementation Plan

本文件只列未完成工作。

## P0：下载抢占设备闭环

- 确认 next/near active transfer 晋升 current 后 effective priority 立即变为 1000；
- 确认满载时 current 在一个 handoff slot 中立即开始，`handoffActive <= 1`；
- 确认被抢占任务清理后复用 partial，不出现同 key 双 writer 或从零重下；
- 分别验证 global cap 与单 source bucket cap。

## P0：纵向 build/layout 设备闭环

- 对比 dev.122 与 dev.123 的 build/layout p50/p95；
- 确认 ratio 更新复用 page shell，滚动时不重复创建页面内容；
- 确认 2→7 屏渐进 warmup 不形成新的单帧尖峰；
- 若 layout 仍高，继续审计 RenderSliver 约束传播，不引入 Reader 图片缓存。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android debug/release 和真机 Trace。
