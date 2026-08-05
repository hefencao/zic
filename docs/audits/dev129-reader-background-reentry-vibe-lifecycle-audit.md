# dev.129 Reader 后台重入与 VibeVenera 生命周期审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.128_native-decode-priority-migration.zip`
- 设备证据：`zic-debug-trace-2026-08-04T23-49-35.jsonl`
- 只读参考：`vibevenera-master(4).zip`

## 问题分类

### 产品问题

- 退出 Reader、切换后台、返回前台并再次进入同一 Reader 后，首帧虽然约 46–90 ms 可见，但前数秒动画严重卡顿。
- Flutter DevTools 未显示对应 build/raster jank，因为阻塞位于 native texture / MethodChannel playback 路径。

### 生命周期问题

- ZIC 把已使用的 `SurfaceProducer` lease、其 retained native frame 与 DecodeId 一并放回进程级 idle pool；新 Reader session 再次取得同一个 platform output。
- 设备 Trace 中同一 DecodeId 连续跨多个 Reader session 以 `textureLeaseReused=true` 恢复。
- 第二次长后台后的 session 仍能快速恢复首帧，但前 15 帧的 present 多次达到约 217–232 ms；平台调用本身多为十余毫秒，主要延迟出现在 MethodChannel round-trip / bridge 回调阶段。

### 播放与 CPU 调度问题

- ZIC 使用 4 ms `Timer.periodic` 轮询所有 upload session 的 deadline；轮询不会提供比下一 deadline 的单次 wake 更多信息。
- 长后台后的 native decode 由正常约 52–64 ms 连续退化到约 215–227 ms，比例接近四倍。
- VibeVenera 源码明确记录 Android EAS 可能把普通 decode thread 留在效率核心，并观察到约四倍退化；其 worker 启动时会 best-effort 绑定最高频核心。

## VibeVenera 参考结论

- 可见 `ImageStreamCompleter` 自己拥有 texture；completer dispose 时直接调用 texture `dispose`，不会把已使用的 `SurfaceProducer` 跨可见会话复用。
- Reader detach 是逻辑 detach；Download/Decode session 可继续由全局 PipelineController 管理，但 platform texture 不作为跨 Reader 缓存。
- 播放使用 holder 信号 + 单次等待：呈现一帧后按 nominal duration 扣除 present 开销，再等待下一次 deadline；没有 4 ms 周期轮询。
- Android decode thread 启动时探测大核并设置 affinity；系统拒绝时保留默认调度。
- App lifecycle 只门控 playback；返回前台后由现有 holder 信号恢复。

## 所有权

- Reader session 创建/销毁：`pipeline_runtime`。
- Android texture 与 SurfaceProducer：`texture_bridge` / `pipeline_native`。
- frame deadline 与播放状态：`sessions/UploadSession`。
- decode worker affinity：`native/media_core` / `bridge`。
- deadline wake：`pipeline_runtime`，只消费 sessions 的只读下一截止时间。
- Reader UI 不持有 texture、timer、decoded frame 或 native cursor。

## 拒绝方案

- 不继续调整 download/decode priority、水位或 startup buffering；本 Trace 中首帧和 decode 已正常产生。
- 不增加 native worker 或扩大长期帧缓存。
- 不继续跨 Reader session 复用已使用的 SurfaceProducer。
- 不用 Flutter Widget 私有图片缓存替代 Pipeline 所有权。
- 不保留 4 ms polling 仅靠更小周期掩盖 deadline 延迟。

## 计划

1. 已使用的 texture lease 在 Reader output 释放时物理释放，不再返回 idle pool；idle pool 只存放尚未承载页面输出的预热 lease。
2. 移除跨 Reader session retained platform output 恢复；新 Reader 使用 fresh SurfaceProducer，正常 source/decode 仍按既有 current 优先级执行。
3. App 进入非 resumed 状态时清理未使用的 prewarm lease，避免后台后复用旧 producer。
4. 用最近 deadline 的 one-shot timer 替换 4 ms `Timer.periodic`；upload snapshot、observation、pause/speed 变化时重算。
5. Android decode worker 启动时 best-effort 绑定高性能核心，并记录 `workerPlacementStatus`。
6. 增加 Trace/analyzer 指标，验证 used texture 不跨 Reader 复用，且 bridge/schedule/native decode 不再连续维持 200 ms 级。
