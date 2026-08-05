# ADR 0113：Fresh Reader Texture、性能核心 Decode 与 Deadline Wake

> dev.134 注：本文的 performance-core affinity 决策已由 ADR 0117 取代；fresh texture 与 deadline wake 决策仍有效。


**状态：Provisional**；后台 texture 调度/affinity 或热字节交付部分由 ADR 0116 取代

## 问题

dev.128 设备 Trace 显示，退出 Reader、长后台后重新进入同一章节时首帧仍约 46–90 ms，但前数秒播放严重卡顿。复用 texture 的 bridge/schedule 可达到 100–230 ms，native decode 也由正常约 52–64 ms 连续退化到约 215–227 ms。Flutter build/raster 并不是主要耗时。

## 参考

VibeVenera 的可见 texture 随 `StreamingImageCompleter` 销毁而释放，不把承载过页面 output 的 `SurfaceProducer` 跨可见会话复用。其 Android decode thread 还会探测高性能核心并 best-effort 设置 affinity；源码注释记录 EAS 把线程留在小核时约有四倍退化。

## 决策

1. 已承载页面 output 的 Android texture lease 在 output 生命周期结束时真实释放，不返回进程 idle pool。
2. idle pool 只保存从未呈现过的预热 lease；App 非 resumed 时清理这些 idle lease。
3. 删除跨 Reader retained platform output 恢复。下载、artifact、partial source、decode worker 和 FrameBudget 所有权不变。
4. playback 使用最近 deadline 的 one-shot timer，不再以 4 ms `Timer.periodic` 扫描全部 upload session。
5. 两个进程常驻 native decode worker 启动时，在 Android best-effort 探测 `cpuinfo_max_freq`/`scaling_max_freq`，选择不低于最高频率 80% 的核心并调用 `sched_setaffinity`。
6. 同构 CPU、探测不可用或系统拒绝均为非致命路径，保持系统默认调度。
7. `frameDecoded.workerPlacementStatus`：0=非 Android/未投影，1=绑定成功，2=未发现异构高性能 mask，3=系统拒绝。

## 所有权

- used/prewarm texture 生命周期：`pipeline_native` / `texture_bridge`。
- Android worker affinity ABI：`native/media_core`。
- worker 建立与状态投影：`bridge`。
- playback deadline wake：`pipeline_runtime`。
- Reader UI 不持有 texture、decoded frame、worker 或 timer。

## 拒绝方案

- 不继续保留旧 Reader 的 used texture 来换取首帧。
- 不新增 Reader 私有图片 LRU。
- 不增加 decode worker 数量或改变 7/5/3/2 水位。
- 不重新调整下载抢占、启动缓冲或 visible-page demand。
- 不把 affinity 失败视为加载失败。

## 解除 Provisional 条件

Android/Rust 构建通过；异构设备 Trace 可确认 affinity 状态；长后台后的前数秒 native decode 与 bridge/schedule 不再持续四倍退化；首帧与 partial/source-growth 回归通过。
