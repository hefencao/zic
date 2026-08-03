# ADR 0087：Reader 重进与 Android presentation 确认

- 状态：Provisional
- 日期：2026-08-03

## 背景

dev.102 设备 Trace 显示 Flutter build/layout/paint/raster 占用较低，但前帧 presentation 仍有明显长尾，退出 Reader 后再次进入更严重。旧 Trace 使用每个 Reader 独立的 stopwatch，导出排序后无法可靠判断两个 session 是否重叠；Android texture 还通过默认 MethodChannel platform handler 和单一全局 blit lane 处理全部 output。播放计时在 MethodChannel Future 完成后才启动，也会把确认延迟重复加入每一帧时长。

## 决策

1. `SystemClock` 使用进程级 monotonic epoch；Pipeline Reader 记录 create、dispose-start、disposed 生命周期事件。
2. Android texture MethodChannel 使用 background task queue。平台要求主线程的 producer create 与 `scheduleFrame` 仍显式投递 main looper。
3. 使用两条 blit lane，并在 output 创建时稳定分配；同一 output 保持串行，不同 current/transition output 不再被单 lane 强制串行。
4. `scheduleFrame` 使用 main queue 前部投递；回复仍发生在 `scheduleFrame` 执行之后。
5. playback deadline 最多抵扣一个名义帧周期的 platform acknowledgement 延迟，不能无限回溯或跳过多帧。
6. decode role 与 upload role 不同时，decoded-to-upload 间隔记为预解码 lead，而不是 upload backpressure。

## 所有权

- monotonic clock 与 Trace event：`telemetry`；
- Reader session lifecycle：`pipeline_runtime`；
- playback deadline 与逐帧 timing：`sessions`；
- Android texture thread/queue：`texture_bridge`。

## 未验证

需要 Android 真机 Trace 证明前帧和 Reader 重进长尾改善，并确认 background task queue 与 front-of-queue 没有引入 producer 生命周期竞态。完成前保持 Provisional。
