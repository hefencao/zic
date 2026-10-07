# dev.128 验证结果

## 输入

- 基线：`zic_v0.31.0-dev.127_startup-buffer-refill-closure.zip`
- 设备 Trace：`zic-debug-trace-2026-08-04T15-47-56.jsonl`

## Trace 基线

- `firstFrameReadyCount=10`；mount-to-first-frame 中位约 41 ms、最大约 295 ms。
- `playbackBufferingOutstandingCount=0`，说明 dev.127 的特定 startup-buffer refill 死锁已闭合。
- page 9 source 在成为 current 前约 3.7 秒已完整 ready/promoted，但 host dispose 时仍 `firstFrameReady=false`。
- page 9 decode 最初以 far/nonCurrent 请求进入 worker pool；需求随后升为 current priority 1000，但无 frameDecoded。
- page 7 retained output 在 current 期间没有 authoritative successor；旧 decode 直到页面降为 previous 后才完成。
- 修复前 Trace 不包含 `decodePriorityPromoted`，analyzer 计数为 0。

## 实现验证

- queued native request 可按 cursor address 与 epoch 从 nonCurrent 队列原位迁移到 current 队首。
- active native request 不被中断，只更新 worker execution class。
- worker pool 首次启动期间先登记 pending request，两个 worker 全部 ready 后统一调度。
- DecodeSession、DecodeRegistry 与 LiveCoordinator 通过窄能力投影迁移，不向 Reader 暴露 worker 或 cursor。
- owner tests 覆盖手动 cursor promotion，以及 far active task 在 role 升为 current 时由 LiveCoordinator 触发 promotion。
- Trace analyzer 支持 queued/active promotion 计数。

## 已通过

- repository、documentation、Dart structure、directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.128 历史所有权门禁；
- test quarantine、demand stability、Reader streaming/layout/UI；
- Trace analyzer、vertical geometry、texture schedule；
- Android texture Kotlin stub 与 runtime/Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only、chapter；
- Venera network、native、headers、preflight、bootstrap；
- source binding、外部登录与设置；
- Python compile、shell syntax、native header；
- 锁定 `libwebp-1.6.0.zip` 的全新 shared host build；
- incremental 与 loop Animated WebP smoke。

## 未验证

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK/Gradle 和 ADB，因此没有声称：

- `flutter analyze` 或 Dart/Flutter owner tests 已实际运行；
- Android release APK 已构建；
- dev.128 native priority migration 已完成真机验证。

## 稳定文档

README、Architecture、Spec 未修改。
