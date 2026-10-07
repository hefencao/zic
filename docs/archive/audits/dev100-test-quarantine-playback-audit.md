# dev.100 测试隔离与前帧播放审计

## 问题清单

### 编译错误

- `library_ui_test.dart` 使用未限定的 `localComicDetailsScreenKey`，实际符号由 `comic_details.dart as details` 导入。
- `misc_settings_test.dart` 使用 `SchedulerBinding`/`SchedulerPhase` 却未导入 `flutter/scheduler.dart`。

### 产品错误

- Android texture 已完成 RGBA blit 后仍先排 `scheduleFrame`、再排第二个 result runnable；UI 队列繁忙时，Dart playback timer 被不必要地再延迟一次。
- dev.99 timing 将 successor 提前解码与 deadline 后阻塞合并为 `decodedToUpload`，导致诊断主导阶段错误。

### 性能问题

- 新 Trace 302 个精确帧样本中，记录值有 292 个 `decodedToUpload` 主导；按前帧 deadline 归一化后，主导项为 `platformResultDispatch` 152、`nativeDecode` 107、`uploadBackpressure` 25、`channelDispatch` 11，其余较少。
- 首个样本 `outputPrepare≈940 ms`、`present≈1008 ms`，平台像素操作只有毫秒级，而 result/channel dispatch 合计接近 1 秒。
- local artifact 已使用 1 MiB chunk；19 次读取的完整 stream p95 约 2.30 秒，但首帧可在 1 MiB committed prefix 上开始，因此不能把完整流结束时间等同于首帧 decode 阻塞。

### 测试错误

- `raster_plan_test` 以 target canvas 的最小尺寸推断最终 renderer upscale，概念不成立。
- Reader download 按钮两项测试的 callback 条件与期望互相颠倒。
- App 重复测试 `reader_runtime` classifier，且断言已落后于实际 evidence 合同。
- `webp_preview_test` 用 `FilterQuality.none` 证明 codec 未放大，测试了错误层。
- pull refresh 测试错误要求不持久化章节 metadata；正确限制是不得预下载章节正文。
- refresh join 使用手势与门控 Future 竞争，无法稳定证明 in-flight 合并。
- 三个 Whole-App Source Browser 测试把 source enablement、catalog、lazy card、route 和真正 locator/retry 所有者揉成一条超时链。

## 所有权清单

| 状态/资源/命令 | 当前正确所有者 | 本轮处理 |
|---|---|---|
| Adaptive reader classification | `reader_runtime` | 删除 App 重复测试，保留 owner package 测试。 |
| Decode target / downsample | `pipeline.RasterPlan` | 只判断 decode 是否 downsample；不猜 widget upscale。 |
| Flutter image filtering | `local_media_ui` Presentation | 测试 renderer 属性，不冒充 codec resize 证据。 |
| Source locator normalization | `plugin_host` adapter / App gateway composition | Whole-App 超时测试隔离，低层 owner 测试继续运行。 |
| Remote details retry UI | details Presentation + injected source Future | 要求后续直接 screen harness，不经主页/catalog bootstrap。 |
| Android texture schedule | `texture_bridge` platform implementation | platform thread 执行完成后才允许成功回复。 |
| MethodChannel present reply | `texture_bridge` blit lane | schedule 完成后直接 reply，删除第二次 main-thread post。 |
| Decode lead/backpressure | `sessions.UploadSession` | 保存前帧 deadline，拆分两个时间字段。 |
| Quarantine allow-list | repository tooling | 文档登记 + 静态门禁。 |

## 被否决方案清单

- 修改产品导航/来源持久化来迎合旧 Whole-App fixture。
- 对所有失败一律删除测试；仍有明确回归意图的测试必须隔离并保留解除条件。
- 匿名 skip、永久 skip 或仅写 flaky。
- 继续在 App 层复制低层算法测试。
- 让 Android present 在 `scheduleFrame` 真正执行前返回。
- 将 intentional predecode lead 当作 upload contention。
- 关闭预下载、缩小 7/3 或 2/1 窗口来降低 timing 数字。
