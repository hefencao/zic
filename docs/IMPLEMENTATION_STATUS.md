# zic Implementation Status

**源码版本：** `0.31.0-dev.134`
**App build：** `0.31.0+134`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 下载前 7 / 后 3，active rank migration 与唯一 current handoff 保持。
- 动画 staged c/n/m/p 水位为 7/5/3/2；静态一帧即满足。
- playback 使用 holder producer/consumer：缺少 successor 时保持当前 output，producer 新帧到达后继续；没有 startup-buffer gate。
- NativeCursor 首帧单帧请求，current 后续最多双帧批量 decode；仍为两个常驻 worker。
- 完整本地不可变页面正文进入 composition-owned ArtifactCacheManager 10 项/256 MiB 热字节 LRU。
- `PipelineReaderSessionHost` 通过 factory acquire/release 管理章节资源会话；同章同 source revision 最多保留 1 个 idle 会话、TTL 2 分钟。
- retained 资源会话保留 DownloadRegistry、SourcePool、DecodeRegistry、artifact handoff、media runtime 与 workspace；Reader binding、page projection、playback wake 和 used texture 会释放。
- 已承载页面 output 的 Android texture lease 随 output 生命周期真实释放；只复用未呈现的 prewarm lease。
- Android texture bridge 使用默认 platform MethodChannel、单串行 blit lane 与普通主线程 `post`。
- Android performance-core affinity 已删除；`workerPlacementStatus` 仅保留 Trace schema 兼容并投影为 0。
- partial source-growth、native decode priority migration、one-shot playback deadline 保持。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity：`zic-media-core-dev134-abi6-lib00121400`。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.134 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Rust/Cargo Android target compile | Unverified：当前环境无 Cargo/NDK |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK 与后台重入设备验证 | Unverified-device |
