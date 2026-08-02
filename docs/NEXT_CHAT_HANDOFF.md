# dev.91 handoff

唯一后续基线：`zic_v0.31.0-dev.91_page-revisit-local-media-trace.zip`。不得混入 dev.90 或更早候选。

## 当前边界

- UploadSession 拥有 renderer output retirement；DecodeSession 拥有 cursor/FrameHolder 重建。LiveCoordinator 只调度，不得把重建逻辑移入 Reader/App。
- demand detach 与 frame-budget trim 必须使用同一 output-loss re-prime；动画正常 frame advance 不重启。
- Reader 继续只消费 PipelinePageOutputStream，不保留 bytes、ImageProvider、texture 或 mutable session。
- `sourceRead`、`frameDecoded`、`frameUploaded`、`framePresented`、`playbackFrameDue` 和 `pageOutputReleased` 是诊断事件，不成为进度或播放状态的第二权威来源。
- Pipeline 7/3、2/1、current/transition、5/3/2 与 256 KiB I/O 不得为掩盖问题而缩小。

## 设备复验

1. 静态、Animated WebP 和其他动画页面来回切换，确认回页不再无限 loading。
2. 导出 Trace，检查 output 退休后 `pageOutputReleased.decodeRestarted=true`，随后出现新 `frameDecoded/frameUploaded/firstFrameReady`。
3. 本地大图或缓存图慢时，比较 `sourceRead` 的 open/firstChunk/stream/maxChunkGap 与 decode/upload/present 耗时。
4. 动画卡顿时检查 `playbackFrameDue.lateByMicros`，并关联下一帧 decode/upload/present。

## 未验证

当前环境无 Flutter/Dart/Android SDK/Cargo。analyzer、Dart/Flutter tests、Android build、Rust tests 和真机性能仍需具备工具链的环境执行。
