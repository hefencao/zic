# dev.131 验证结果

## Trace 基线

输入：`zic-debug-trace-2026-08-05T00-49-36.jsonl`。

- `pageHostDisposedWithoutFrameCount=2`：page 15（session 11）与 page 19（session 13）在挂载生命周期内没有首帧。
- `playbackRebufferCount=2`：同一动画已进入 running 后再次出现 `playbackBuffering waiting`。
- `playbackBufferingOutstandingCount=1`：frame 14 的再次缓冲等待约 2.815 秒后随 output detach 结束。
- `decodePriorityPromotionCount=770`，其中 active promotion 769 次；大部分为 worker 已经是 current 后的重复报告。
- worker affinity 状态均为 3；本轮没有继续修改 affinity。

## 修复

- startup-current gate 暂缓其他 DecodeId 时，source revision 保持 pending，并记录 `decode-startup-deferred`。
- 已完成 startup buffer 的 output 跨临时 transition/previous 保留完成状态，返回 current 不再中途重新缓冲。
- native active worker 已经是 current 时，promotion 返回 none。
- Analyzer 新增 `decodeStartupDeferredCount`、`playbackRebufferCount`。

## 已执行并通过

- repository、documentation、Dart structure、directive order、Pipeline compile boundary；
- dev.75–dev.131 历史 ownership gates；
- quarantine、Trace analyzer、vertical geometry、texture timing；
- Android texture Kotlin stub；
- Android runtime/Trace、Mihon、Venera、Reader、Pipeline、UI、source binding、登录与设置合同；
- native header；
- 锁定 `libwebp-1.6.0.zip` 的全新 shared host build，以及 incremental/loop smoke。

## 未验证

当前环境没有 Dart/Flutter SDK、完整 Android SDK/NDK、Cargo/rustc 和 ADB，因此没有执行 `flutter analyze`、Dart/Flutter owner tests、Android APK、Rust Android target 或设备验证。
