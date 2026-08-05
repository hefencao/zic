# zic Implementation Status

**源码版本：** `0.31.0-dev.133`
**App build：** `0.31.0+133`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 下载前 7 / 后 3，active rank migration 与唯一 current handoff 保持。
- 动画 staged c/n/m/p 水位为 7/5/3/2；静态一帧即满足。
- playback 采用 VibeVenera 风格 holder producer/consumer：首帧立即呈现，缺少 successor 时保持当前 output 并等待 producer 唤醒；没有 startup-buffer eligibility gate。
- NativeCursor 首帧单帧请求，current 后续最多双帧批量 decode；两个常驻 worker、7/5/3/2 staged 水位保持。
- 完整本地不可变页面正文进入 composition-owned ArtifactCacheManager 10 项/256 MiB 热字节 LRU；current memory hit 以单个 body 直接进入既有 native ingress。
- deadline lead、partial source-growth 与 native decode priority migration 保持。
- 已承载页面 output 的 Android texture lease 随 output 生命周期真实释放；进程 texture pool 只复用从未呈现的预热 lease。
- Android 进入非 resumed 生命周期时清理未使用的 prewarm lease，不恢复旧 Reader 的 platform output。
- playback 由最近 deadline 的 one-shot timer 唤醒，不再使用 4 ms 周期轮询。
- 两个进程常驻 native decode worker 使用实际 TID，并将高性能 mask 与当前 Android cpuset 求交后 best-effort 绑定；结果通过 `workerPlacementStatus` 投影到 Trace。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android texture bridge 使用默认 platform MethodChannel、单串行 blit lane 与普通主线程 `post`；不使用 background task queue 或 front-of-queue schedule。
- Android native build identity：`zic-media-core-dev133-abi6-lib00121300`。
- Android output projector 已完成 retained output 删除后的编译闭包，只接受 `_AndroidTextureOutputFrame`。
- native active current promotion 为幂等，避免 observation/source wake 重复记录相同 promotion。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.133 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Rust/Cargo Android target compile | Unverified：当前环境无 Cargo/NDK |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK 与后台重入设备验证 | Unverified-device |
