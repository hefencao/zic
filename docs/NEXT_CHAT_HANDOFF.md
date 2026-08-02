# 下一聊天交接

唯一后续基线：`zic_v0.31.0-dev.94_vibe-webp-worker-pipeline.zip`。不得混入 dev.93 或更早候选。

## 已完成

- 保留 dev.92/93 的静态、有限动画、successor 与 direct-fd 修复。
- `bridge` 增加两个常驻 native decode Isolate；UI isolate 不再同步执行 `zic_cursor_decode_next`。
- isolate 只传 cursor/frame native 地址与小型 metadata，不传像素。
- `media_core` 持久缓存 demux frame descriptors；source length/seal 不变时逐帧与 rewind 复用。
- descriptors 使用 authoritative source-relative offset/length，不保留第二份完整压缩 bytes。
- libwebp advanced decode 开启 `use_threads=1`。
- 保留 dev.82 source-grid composition，删除每帧 full-canvas clone；现有 Android serial native blit 不重复实现。
- `frameDecoded` 增加 `nativeDecodeMicros` 与 `decodeDispatchMicros`。

## 设备复验重点

1. 过滤同一 DecodeId 的 `frameDecoded`：比较 total/native/dispatch；dispatch 不应再包含 UI isolate 被同步 FFI 占用的整个 decode。
2. 比较 Android texture `queueMicros/uploadMicros/roundTripMicros/bridgeMicros`；bridge 等待应从 dev.93 的数百毫秒到秒级明显下降。
3. 检查 33/34 ms 动画的实际流畅度与 `successorBuffered`；如果 native decode 仍慢，下一步只优化 media_core source-grid scaler/输出复制。
4. 检查横向条带、blend/dispose、有限循环、回切和末帧保留。
5. 远程部分图片无法下载是独立后续项。

## 约束

Reader/App 不得新增帧、字节或 texture cache。Decode worker 属于 `bridge` 平台执行层，demux/canvas 属于 `media_core`，sessions 只拥有 demand/trace。禁止恢复目标网格独立 ANMF rect 缩放；保留 7/3、2/1、current/transition、5/3/2、256 KiB 与 GET/HEAD 零 body。
