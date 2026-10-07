# ADR 0110：启动播放缓冲与 Deadline Lead

**状态：Provisional**

## 问题

dev.125 已恢复首帧加载，但低性能设备进入 Reader 后前几秒仍明显掉帧。Trace 显示 Flutter build/raster 并非主因：30 fps WebP 的标称 duration 约 33 ms，实际可见间隔常为 54–69 ms，并有超过 100 ms 的停顿。旧流程在 frame 0 呈现后立即启动动画，current successor 水位尚未建立；同时只有 deadline 到达后才开始 successor upload/present，实际帧间隔叠加 ticker 与平台呈现成本。

## 决策

1. frame 0 仍立即显示。
2. 对权威 `frameCount >= 7` 的 current 动画，根据帧时长建立约 250 ms、最少 2 帧、最多 7 帧的启动 successor 目标。目标未满足时暂停 playback timer。
3. 启动缓冲期间，LiveCoordinator 只允许该 current DecodeId 参与 refill；其他 demand 不删除，缓冲 ready 后恢复原仲裁。
4. 后续 deadline 使用上一帧从 present 调用到实际平台可见调度的测量耗时作为 lead，且不超过一个 nominal duration。
5. runnable playback 存在时 ticker 使用 4 ms；静态、暂停、冻结和无活动播放时不运行。
6. 长期 c/n/m/p 水位仍为 7/5/3/2，不增加 30 帧 RGBA 缓存。

## 所有权

- 启动缓冲、播放 timer、deadline lead：`sessions/UploadSession`。
- 启动期 decode refill eligibility：`sessions/LiveCoordinator`。
- 活动 ticker：`pipeline_runtime`。
- Reader、Widget、texture bridge 不拥有该策略。

## 否决方案

- 不降低播放速度或修改 WebP duration。
- 不把 native/output cadence 问题包装成 Flutter UI jank。
- 不扩大长期水位或预存 30 帧 RGBA。
- 不删除 next/next+1 demand，只在 current 启动缓冲期暂缓其 refill。
- 不在 Reader 中增加 timer、frame queue 或 texture cache。

## 解除 Provisional 条件

真机 Trace 出现 `playbackBuffering waiting/ready`，current 在开始连续播放前达到目标深度，visible frame cadence 明显接近 nominal duration，且静态页、短动画、用户暂停、transition freeze 与后台 retained output 无回退。
