# 下一聊天交接

唯一后续基线：`zic_v0.31.0-dev.93_animation-successor-local-fd-trace.zip`。不得混入 dev.92 或更早候选。

## 已完成

- dev.92 的静态零时长与有限动画末帧生命周期保持不变。
- 修复错误报告中的四类测试闭包：LoopCursor fixture、50/50 overlap、source seal revision、local media transformed geometry/fitWidth。
- 当前动画 output 不再冒充 prepared successor；同一 DecodeSession 在当前帧显示期间最多预解码一帧。
- deadline 前不提前替换；deadline 后优先消费缓冲 successor，没有 successor 时保留旧 output。
- texture Trace 增加 `roundTripMicros` 和 `bridgeMicros`。
- Android 本地媒体桥协议 v5：seekable document descriptor 走同进程 direct-fd 256 KiB stream，不可 seek/无法重开时回退 readDocumentChunk。

## 设备复验重点

1. 过滤同一 identity 的 `frameDecoded -> frameUploaded -> framePresented -> playbackFrameDue`；到期时应经常出现 `successorBuffered=true`。
2. 比较 `decodeMicros`、UploadSession `uploadMicros`、Android texture `queueMicros/uploadMicros/roundTripMicros/bridgeMicros` 和 Presentation `presentMicros`。
3. 静态图仍应 `playbackScheduled=false`，有限动画结束应 `playbackCompleted.outputRetained=true`。
4. 对比 direct-fd 修复后的 origin `content://` sourceRead；仍慢时检查 firstChunk/maxChunkGap。部分远程图片下载失败仍是独立后续项，不得通过缩小 7/3 或 2/1 窗口掩盖。

## 约束

Reader/App 不得新增图片字节、last-frame 或 texture 缓存。UploadSession 仍是 renderer output 唯一所有者，DecodeSession 仍是 cursor/FrameHolder 唯一所有者。保留前 7/后 3、前 2/后 1、current/transition、5/3/2、256 KiB 和 GET/HEAD 零 body。完整验证顺序继续遵守 AGENTS.md。
