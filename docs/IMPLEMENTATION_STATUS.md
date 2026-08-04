# zic Implementation Status

**源码版本：** `0.31.0-dev.127`
**App build：** `0.31.0+127`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 下载前 7 / 后 3，active rank migration 与唯一 current handoff 保持。
- 动画 staged c/n/m/p 水位为 7/5/3/2；静态一帧即满足。
- current 长动画 frame 0 立即显示，随后建立约 250 ms、最多 7 帧 successor 启动缓冲。
- startup buffering current 可在同一 DecodeId 上连续推进后续 staged refill，不再停在第一档水位。
- upload 在首帧后才进入 buffering 的竞态由定向 decode scheduling 闭合。
- playback deadline lead、4 ms 活动 ticker、后台 retained output 与 partial source-growth 边界保持。
-正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity 未变，本轮未修改 Rust/JNI 或 Kotlin。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.127 ownership gates | 待正式交付前完整复验 |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | 待正式交付前完整复验 |
| pinned libwebp host build/smoke | 待正式交付前复验 |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK 与真机 buffering closure | Unverified-device |
