# ADR 0077: 动画 successor 缓冲与 texture bridge Trace

## 状态

Accepted for `0.31.0-dev.93`.

## 背景

用户确认 dev.92 消除了持续无限 loading，但新的设备 Trace 显示本地动画仍卡顿。动画帧目标时长约 33/34 ms，而单帧解码多为 120–150 ms。旧 `UploadSession.preparedDepth` 只要存在可见 output 就返回 1；对动画而言，这把当前 presentation output 错当作未来准备帧，使 DecodeSession 在当前帧显示期间停止工作。播放 deadline 到达后才投影 0 并开始解码，必然产生至少一个 decode latency 的停顿。

同时 Android native texture telemetry 只报告 native queue/upload，Dart 侧 `presentMicros` 明显更长时无法区分 MethodChannel 往返、线程调度或其他竞争。

## 决策

1. 当前可见动画 output 不计入 successor prepared depth；静态 output 仍计 1。
2. DecodeSession 使用现有 cursor/FrameHolder 和 target watermark 在当前帧期限内最多预解码一帧 successor，不新增缓存层。
3. UploadSession 在 `_awaitingSuccessor=false` 且当前动画 output 仍在 deadline 内时，不得提前消费 holder 中 successor。
4. deadline 到达后 LiveCoordinator 同时唤醒 upload 和 decode：holder 已有帧时立即上传替换；没有时旧 output 保持可见，decoder 完成后再唤醒 upload。
5. dev.92 的有限动画 ended/final output 保留和静态零时长规则继续有效。
6. AndroidTexturePresenter 在 MethodChannel 调用外测量 `roundTripMicros`；`bridgeMicros=max(roundTrip-queue-upload,0)` 只作诊断。
7. Android document bridge 协议升至 v5。对 seekable `AssetFileDescriptor`，native 持有 descriptor 并返回同进程 `/proc/self/fd`、起止 offset；Dart `RandomAccessFile` 直接按 256 KiB 读取。不可 seek或 direct open 在首字节前失败时回退 MethodChannel chunk。
8. 不改变页面预解码范围、上传窗口、lane、I/O 分块或 renderer output 数量上限。

## 被否决方案

- 提高动画播放 deadline 到实际 decode 时长：会掩盖 pipeline 未并行准备 successor，并改变内容原始节奏。
- 提前上传 successor 并立即替换：会在当前帧 duration 未结束前跳帧。
- 在 Reader 保存上一帧或建立动画帧队列：形成与 UploadSession/DecodeSession 竞争的所有者。
- 扩大 current/transition 页面上传窗口：增加纹理占用且不解决同一页面 successor pipeline。
- 把 native queue/upload 直接等同完整 present 耗时：忽略 platform-channel 和调度等待。
- 把 `content://` 整文件复制到 App 私有目录再解码：重复 I/O、占用空间，并建立不必要的本地副本生命周期。

## 影响

动画可以把当前帧显示时间与下一帧 decode 重叠；当 decode 仍慢于目标 duration 时无法凭空达到原始帧率，但不再额外串行等待。Trace 可区分 codec、native upload 和 bridge/presentation 等待。seekable Android document 可消除每个 256 KiB chunk 的 MethodChannel 往返；provider pipe/virtual document 仍使用原 fallback。