# dev.95 高性能设备 WebP/缓存链审计

## 问题清单

### 编译与契约

- native ABI 需要同时更新 Rust、C header、Dart FFI、版本检查和 header smoke。
- `ArtifactCacheStreamStore` 加入 managed service 后，内存和持久实现必须同时闭包。
- dev.82/dev.94 静态门禁仍硬编码旧 source-grid/full-scale 描述，需要改为端点一致性门禁，而不是保活退化实现。

### 产品

- 高性能设备首帧仍约 1.7–2.3 秒，不能归因于硬件。
- promoted cache 命中仍整页物化并复制到 Reader 临时 session。
- `PromotedArtifactReadPool` 与 cache transport 可同时读取同一完整文件。
- source 增长时 demux 过于频繁重建。

### 性能

- 71 次 native decode 中位约 70.7 ms；native texture blit 中位约 0.9 ms。
- platform round trip 中位约 24.2 ms但最高约 1.59 秒，极值与多页 artifact copy 重叠。
- `DownloadSession -> Artifact -> NativeSource` 旧链包含两份 Dart chunk copy、临时 native allocation/copy、Rust Vec copy和逐 chunk awaited file write。
- 每帧 source canvas 完整浮点 bilinear scale 是 VibeVenera 路径不存在的额外 O(target pixels) 工作。

### 测试

- 需要 promoted stream 不调用 `readArtifact` 的 owner test。
- 需要 artifact exact range stream test。
- 需要 native reserve/commit ABI/header smoke。
- 需要相邻/奇数 frame rectangle 的无缝端点映射测试。

## 所有权清单

| 状态或资源 | 正确所有者 | dev.95 处理 |
|---|---|---|
| promoted artifact 文件 | downloads/storage | 只读范围流，不向 Reader 泄漏 path |
| Reader 活跃 encoded source | DownloadSession/Ingress | cache 流仍进入同一 session |
| chunk durability | Artifact | IOSink 缓冲，seal/pause flush |
| native source 容量与 committed length | media_core ByteSource | expected-capacity + reserve/commit |
| demux descriptor | media_core Decoder | source-relative offset/length，受控刷新 |
| blend/dispose canvas | media_core Decoder | 最终 target grid |
| upload/present | UploadSession/texture_bridge | 未改变 |
| 页面 demand/窗口 | Pipeline policy | 7/3、2/1、current/transition、5/3/2 未改变 |

## 被否决方案

- 继续以设备性能不足解释卡顿：同设备 VibeVenera 对照和 Trace 已否决。
- 增大 successor 数量掩盖首帧慢：不能消除 cache copy、native ingress 和 full-canvas scale。
- 缩小预下载窗口或并发：违反已批准行为，并只隐藏竞争。
- Reader 直接读取 promoted file 或持有 bytes：破坏 downloads/session 所有权。
- 多进程或 App 私有图片 LRU：重复状态源。
- 每个子矩形独立 round offset/width：会制造边界缝隙或重叠；必须映射共享 start/end endpoint。
- 保留 source canvas 再完整缩放，仅微调算法：仍执行 VibeVenera 不需要的整帧额外遍历。

## 删除/迁移

- 删除 `NativeSource.append` 每 chunk `calloc<Uint8>` 临时数据区。
- 删除 Rust source append 的必要二次 `extend_from_slice` 路径，兼容 `zic_source_append` 仅作为旧 ABI helper 保留。
- 对流式 cache 关闭 `PromotedArtifactReadPool` 的并发整页 prime。
- 删除 WebP `scale_rgba` 与 source-size canvas。
- 旧 source-grid ADR 保留为历史原因记录，但当前实现由 ADR 0079 基于共享端点映射取代。
