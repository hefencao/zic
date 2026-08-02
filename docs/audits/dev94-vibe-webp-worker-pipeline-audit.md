# dev.94 VibeVenera WebP worker/pipeline 迁移审计

## 问题清单

### 编译错误

- 用户未提供新的编译错误。公共 API 变化限于 `bridge` part 和 `media.FrameDecodeTiming`，所有生产调用方已全仓搜索。
- 风险点是手写 libwebp 1.6 advanced decoder C ABI layout；已对照用户文件库中的 1.6.0 headers，并用 C smoke 编译验证 advanced config/threaded decode。真实 Rust/Android 编译仍需工具链。

### 产品错误

- dev.93 虽不再无限 loading，但本地动画继续严重卡顿。当前页 successor 调度已经工作，问题转入实际执行链。
- UI isolate 同步执行 `zic_cursor_decode_next`，重型 FFI 期间 Flutter 与 MethodChannel completion 均被阻塞。

### 性能问题

- 798 条 Trace 中 `frameDecoded` 17 次，decode 中位 124893 µs、最大 141872 µs。
- 13 次 Android texture round trip 中位 770103 µs、最大 1689081 µs；native queue 中位约 213 µs，native blit/upload 中位约 5625 µs，证明多数时间不是 native texture copy。
- native WebP decoder 每帧重新 demux 完整约 18 MB source，并曾复制完整压缩 snapshot；source canvas composition 前还有一次 full clone。

### 测试错误/缺口

- 缺少禁止 UI isolate direct decode 的门禁。
- 缺少 sealed source 跨帧/rewind 复用 demux 的 fixture。
- 缺少 libwebp advanced config `use_threads=1` 与 external RGBA smoke。
- 当前环境缺少 Dart/Flutter/Rust/Android 工具链，无法执行真实 isolate/native integration test。

## 所有权清单

| 状态/资源 | 当前/正确所有者 | dev.94 处理 |
|---|---|---|
| worker Isolate、decode 队列 | `bridge` 平台执行层 | 两个常驻 worker，owner acquire/release |
| native cursor/frame pointer | `media_core`，Dart `bridge` 只持 opaque handle | pointer-only message，禁止像素复制 |
| demux descriptors、canvas、blend/dispose、rewind | `media_core::webp::Decoder` | source revision 内持久复用 |
| authoritative encoded bytes | Source/DownloadSession | descriptor 仅保存 offset/length，不复制 snapshot |
| decode demand/watermark | `sessions/LiveCoordinator` | 策略不变，只等待异步 cursor |
| renderer output/native blit | `UploadSession`/`texture_bridge` | 复用既有 serial blit，不迁移竞争实现 |
| 页面播放与显示 | Reader Presentation | 只读 output，零新增 cache |

## 被否决方案清单

- 调低 FPS、延长 frame duration 或静默跳帧。
- 缩小预下载/预解码窗口或降低 lane 并发。
- Reader/App 持有 last-frame、frame queue、pixel bytes 或 texture。
- 跨 Isolate 传完整 WebP/像素。
- 复制 VibeVenera 的 Venera 网络/协议代码。
- 恢复独立目标网格 ANMF 子矩形缩放；dev.82 已证明会产生条带/位移风险。
- 复制第二套 Android texture plugin；ZIC 已有正确 owner。

## 参考实现映射

- 参考：VibeVenera `webp_decoder.dart` 两个长期 worker、pointer result；迁移到 `packages/bridge`。
- 参考：`webp_decoder.c` 持久 demux/context 与 `WebPDecoderConfig.use_threads`；迁移到 `native/media_core`，但保留 ZIC source-grid composition。
- 参考：`webp_texture_blit.c` 专用 serial native blit；ZIC 既有实现已等价，无源码并入。
- VibeVenera 源码保持只读，未修改或打包。

## 验证与未验证

已执行 repository/Dart structure、dev.82 source-grid gate、dev.94 ownership gate，以及文件库 libwebp 1.6.0 的 host source build、incremental/loop/threaded decode smoke。最终包仍需重新解压复验。Flutter analyze、Dart/Flutter tests、Rust tests/build、Android Gradle/APK 与设备帧率因工具链不可用列为未验证。
