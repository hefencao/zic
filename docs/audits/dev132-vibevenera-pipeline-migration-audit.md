# dev.132 VibeVenera 流式播放路径迁移审计

## 编译问题

- NativeCursor 当前仅支持逐帧 worker 往返，缺少 VibeVenera 的批量 decode 请求合同。
- 删除 startup buffer 后必须同步移除 UploadRegistry、LiveCoordinator 和 PipelineReaderSession 的查询/唤醒残留。

## 产品问题

- Trace 中 `playbackRebufferCount=6`、`playbackBufferingOutstandingCount=1`；启动缓冲状态机仍会在播放中重新等待。
- Trace 中 17 个挂载页面虽都有首帧，但后台后的 mount-to-first-frame 达到 1.4–2.0 秒。

## 性能问题

- `decodeStartupDeferredCount=431`，current 启动缓冲长期禁止其他 DecodeId refill。
- 本地 `content://` 页面在新 Reader 中重复执行 17–20 MiB `session-copy`；最长流读取约 4.25 秒。
- native decode 约 50 ms/帧，逐帧 isolate/FFI 往返放大 producer 间隙。

## 测试问题

- 现有测试主要证明 startup buffer 能闭合，没有证明播放过程中永不重新进入 startup wait。
- 缺少本地不可变 origin 完成后进入 composition-owned memory LRU、跨 Reader 命中的测试。
- 缺少 NativeCursor 首帧单帧、后续 current 双帧批量请求与未消费 frame 释放测试。

## 所有权

- 播放消费与当前 output：`sessions/UploadSession`。
- decode refill 与 source revision：`sessions/LiveCoordinator`。
- native 批量 worker 请求：`bridge/_NativeDecodeWorkerPool`。
- 本地页面字节 LRU：composition-owned `downloads/ArtifactCacheManager`，不是 Reader/App 私有缓存。
- Reader 继续只消费 `PipelinePageSurface`。

## 否决方案

- 不继续增加 startup target、timer 或 source-wake 特例。
- 不恢复跨 Reader used texture。
- 不缩小 7/3 下载窗口或降低稳定并发。
- 不在 Reader/App 新建图片字节 LRU。
- 不增加第三个 decode worker。


## 实施结果

- 删除 startup-buffer production path：UploadSession 不再发布新 `playbackBuffering`，LiveCoordinator 不再读取播放状态或产生 `decode-startup-deferred`。
- NativeCursor 首帧 batch=1，current 后续 batch<=2；cursor 最多持有一个未消费 native frame，rewind/dispose 释放。
- 完整本地 immutable origin 正常读完且长度吻合后写入共享 ArtifactCacheManager；范围、失败、取消与不完整流不写入。
- 原始设备 Trace 基线：`decodeStartupDeferredCount=431`、`playbackRebufferCount=6`、后台首帧 p95/max=1,999,056us。

## 验证结果

- repository/documentation/Dart structure/compile boundary 与 dev.75–dev.132 静态门禁通过。
- Android/Mihon/Venera/Reader/Pipeline/UI 合同与 Kotlin texture stub 通过。
- 锁定 libwebp 1.6.0 全新 shared host build、incremental/loop smoke 通过。
- 当前环境没有 Flutter/Dart SDK、Cargo/NDK/ADB；Dart owner tests、Android APK 与设备行为仍未验证。
