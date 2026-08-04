# zic Implementation Status

**源码版本：** `0.31.0-dev.126`
**App build：** `0.31.0+126`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 下载前 7 / 后 3，active rank migration 与唯一 current handoff 保持。
- 动画 staged c/n/m/p 水位为 7/5/3/2；静态一帧即满足。
- current 长动画 frame 0 立即显示，随后等待约 250 ms、最多 7 帧 successor 启动缓冲，再启动连续播放。
- 启动缓冲期间只补 current，完成后恢复邻页 decode 仲裁。
- playback deadline 按上一帧实际平台可见 lead 提前；活动 ticker 为 4 ms，无播放时停止。
- 后台恢复可复用同 DecodeId retained output；partial 未封缄 failure 等待 source growth。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity 未变，本轮未修改 Rust/JNI 或 Kotlin。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.126 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK 与真机首几秒 cadence | Unverified-device |
