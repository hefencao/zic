# ADR 0078：常驻 WebP 解码 worker 与持久 frame descriptor

## 状态

Accepted for `0.31.0-dev.94`.

## 背景

dev.93 已允许当前动画帧期间预解码 successor，但设备仍明显卡顿。新 Trace 中 native texture 真正 queue/blit 很短，而完整 platform round trip 长达数百毫秒到秒级。代码审计发现 Dart UI isolate 同步调用 native cursor decode；同一 native decode 又逐帧对完整 WebP source 创建 demux，并复制压缩快照。UI isolate 被重型 FFI 占用时，Android MethodChannel completion 即使 native blit 已完成也无法及时返回。

VibeVenera 的通用 WebP 路径使用常驻 decode Isolate、持久 native decoder/demux、advanced libwebp threaded decode 与专用 native blit。该结构与 Venera 协议无关，可作为只读参考；但其目标网格子矩形合成不能直接覆盖 ZIC dev.82 已验证的 source-grid 语义。

## 决策

1. `bridge` 按 native library 维护两个常驻 decode Isolate。`NativeCursor.decodeNext` 提交 cursor address/epoch 并异步等待 frame address，不在 UI isolate 调用重型 decode。
2. native pointer 生命周期由 cursor owner保证；同 cursor禁止并发 decode，dispose 等待 in-flight 结束。worker 最后一个 owner 释放且队列空时关闭。
3. `media_core::webp::Decoder` 缓存 source-relative frame descriptors、animation metadata、canvas 和播放位置。source 长度/sealed 变化才重新 demux。
4. descriptor 不拥有 encoded bytes；当前 source read lock 保证 fragment offset range 在 decode 期间稳定。
5. libwebp 使用 advanced decoder config、external RGBA 和 `use_threads=1`。
6. blend/dispose 继续在 source pixel grid完成，之后整帧一次缩放。删除逐帧 demux、第二份完整压缩 snapshot 和 composition 前 full-canvas clone。
7. ZIC 已有 Android serial native texture blit，因此不迁移第二套 texture plugin。
8. Trace 分离 native decode 与 dispatch/worker 往返。

## 被否决方案

- 继续增加 successor 深度：单 cursor 逐帧状态依赖，不能用更多缓冲消除同步 UI FFI 和逐帧 demux。
- 降低动画帧率、修改 duration、主动跳帧：隐藏性能错误并改变内容语义。
- 缩小 7/3、2/1 或降低并发：不能修复当前页执行路径。
- 在 Reader 缓存像素、frame 或 texture：与 UploadSession/DecodeSession 竞争所有权。
- 跨 isolate 传完整 `Uint8List`/frame bytes：重新引入大对象复制。
- 直接照搬目标网格 ANMF 子矩形缩放：已在 dev.82 证明可能产生横向条带和相对位移。
- 新建第二套 Android texture presenter：现有 `texture_bridge` 已有专用串行 blit。

## 影响

UI isolate 不再执行重型 WebP decode，平台回调可及时处理。sealed source 的逐帧/rewind 不再重复 demux，source growth 也不复制第二份完整压缩数据。实际设备帧率仍取决于 native decode、source-grid scale 和 upload；新 timing 可进一步区分这些阶段。
