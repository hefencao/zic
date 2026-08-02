# ADR 0079：直接 native ingress、流式 promoted artifact 与目标画布 WebP

- 状态：Accepted
- 版本：`0.31.0-dev.95`
- 基线：`0.31.0-dev.94`

## 背景

高性能 Android 设备上的 Trace 仍显示首帧约 1.7–2.3 秒。native WebP decode 中位约 70.7 ms，Android blit 中位低于 1 ms，但 platform callback 可被阻塞到约 1.59 秒。VibeVenera 在同类文件上可在 200 ms 内开始解码播放并同时预解码下一页，因此不能继续归因于设备性能。

代码对照确认 ZIC 仍存在三条额外工作：promoted artifact 先整页读入 `Uint8List` 并并发重复读取，再逐块复制到临时 artifact；每个 chunk 经 Dart 临时 native buffer 后由 Rust 再复制一次；每帧在源尺寸画布合成后由纯 Rust 浮点循环缩放完整画布。

## 决策

1. `ArtifactCacheStreamStore` 只读暴露 promoted artifact 的范围流。Reader 的权威 `DownloadSession` 消费该流；不再先物化完整 `Uint8List`，`PromotedArtifactReadPool` 对流式 store 不再并发预读整页。
2. `Artifact` 使用 `IOSink` 缓冲写，`DownloadSession` 只创建一份 owned `Uint8List`，同时交给 artifact 与 ingress。durability 在 pause/seal/promote 时 flush。
3. native ABI 6 增加 expected-capacity、reserve、commit。Dart 直接写入 native source 的预留区域，删除每 chunk 的临时 native buffer 与 Rust `extend_from_slice` 二次复制。
4. WebP demux 在已有 descriptor 可满足下一帧时不因 source 增长重建；没有下一 descriptor 时按 512 KiB 或 seal 刷新。
5. WebP 帧 rectangle 使用来源端点统一映射：`floor(start * scale)` 与 `floor(end * scale)`。libwebp 直接将 fragment 缩放到该 target rectangle，在最终 target canvas 上 blend/dispose；删除完整 source canvas 的第二次纯 Rust 缩放。
6. target rectangle 的相邻边界必须共享同一端点，测试覆盖奇数尺寸、横向/纵向相邻条带，禁止恢复独立 round(offset)+round(width) 的错位实现。

## 所有权

- `downloads`：promoted artifact 流式只读能力和 cache transport。
- `storage`：文件、范围读取、缓冲写与 durability。
- `sessions/media/bridge`：唯一 DownloadSession、Ingress、native source reservation/commit。
- `media_core`：demux、目标画布、blend/dispose 与 libwebp scaling。
- Reader/App：不访问 artifact path、fd、native source 或 frame bytes。

## 结果与限制

该决策删除可确认的整页重复读取、临时 artifact 同步 chunk 写等待、Dart→native 双复制和完整画布浮点缩放。当前环境无 Flutter/Dart/Rust/Android 工具链，真实 APK、Rust 编译和设备 200 ms 目标仍需设备复验；若仍慢，应使用 `bytesCommitted` 的 ingress/artifact timing 与 frame decode/upload/present timing继续定位，不得缩小 7/3、2/1 或 5/3/2 窗口。
