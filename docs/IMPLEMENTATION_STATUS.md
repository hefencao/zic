# zic Implementation Status

**源码版本：** `0.31.0-dev.124`
**App build：** `0.31.0+124`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 下载窗口保持前 7 / 后 3；全局/远程并发 5，本地稳定并发 2。
- queued/active rank migration、current 唯一 handoff、离窗 retained transfer 后台 rank 0 保持。
- 本地 current 尚无首个已呈现 output 时，local bucket 临时为 1；首帧真实 present 后原位恢复稳定值 2，不重启 active session。
- output prewarm 使用最终对齐 DecodeTarget，避免来源尺寸与 texture identity 不一致。
- 动画 staged c/n/m/p 为 7/5/3/2；静态一帧即满足；partial prefix 30 帧循环与 retained output 保持。
- 纵向 Reader 的 page-shell 预组合、geometry snapshot 和 2→7 屏渐进轻量 host warmup 保持。
- `.zic-workspace.json` 持久化 `patch_dir`；release 要求完整 ZIP、SHA 和 `git apply --index` patch。
- durable cache、local direct ingress、texture pool、source-wake 与纵向 anchor 阈值保持。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Python static gates | Verified-static |
| dev.124 startup/patch delivery gate | Verified-static |
| exact DecodeTarget prewarm owner test | Unverified：当前环境无 Flutter SDK |
| pinned libwebp host build/smoke | 待本轮最终验证 |
| Android APK | Unverified：当前环境无 toolchain |
| 低性能设备大 WebP 首帧 ≤400 ms | Unverified-device |
