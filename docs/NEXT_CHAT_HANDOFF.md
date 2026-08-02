# dev.92 handoff

唯一后续基线：`zic_v0.31.0-dev.92_static-finite-output-lifecycle.zip`。不得混入 dev.91 或更早候选。

## 当前边界

- UploadSession 独占 renderer output、present claim、playback timer 与 successor replacement；动画到期时旧 output 保持到新 output 上传成功。
- PlaybackTimer 不接受零/负时长；已确认静态帧不得触发 playback advance。
- DecodeSession 独占 cursor、AnimationInfo 与 FrameHolder。等待 successor 时 ended 表示有限动画完成，不得由 Reader 推断。
- ADR 0075 仅处理 demand detach/frame-budget 的真实 output 退休和 cursor re-prime；ADR 0076 处理同一 UploadSession 内的帧替换，两条路径不得重新合并成 Presentation 缓存。
- Reader 继续只消费 PipelinePageOutputStream，不持有 last frame、bytes、ImageProvider、texture 或 mutable session。
- `sourceRead/frameDecoded/frameUploaded/framePresented/playbackFrameDue/pageOutputReleased/playbackCompleted` 只用于诊断，不成为播放权威。
- 7/3、2/1、current/transition、5/3/2 和 256 KiB I/O 不得为掩盖问题而改变。

## 设备复验

1. 静态图前后切换，确认零时长呈现后没有 playback due，回页不再无限 loading。
2. 动画前后切换并观察慢帧，确认旧 output 保持到 successor 上传，不出现空白/loading 闪烁。
3. 有限动画结束后检查 `playbackCompleted.outputRetained=true`。
4. 本地/缓存大图或动画仍慢时，继续导出 Trace，并按 sourceRead、decode、upload、present 与 deadline 分段过滤。

## 未验证

当前环境无 Flutter/Dart/Android SDK/Gradle/Cargo。必须在具备工具链的机器运行 analyzer、受影响 storage/texture_bridge/sessions/reader_runtime/App tests、Android debug/release 或 kernel snapshot，并进行真机回切与动画播放验证。
