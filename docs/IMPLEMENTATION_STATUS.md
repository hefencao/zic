# zic Implementation Status

**源码版本：** `0.31.0-dev.128`
**App build：** `0.31.0+128`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 下载前 7 / 后 3，active rank migration 与唯一 current handoff 保持。
- 动画 staged c/n/m/p 水位为 7/5/3/2；静态一帧即满足。
- current 启动缓冲、deadline lead、4 ms 活动 ticker、后台 retained output 与 partial source-growth 边界保持。
- outer DecodeLane demand role 升为 current 时，已排队的 native nonCurrent 请求可按同 cursor/epoch 原位迁移到 current 队首。
- active native call 不强制中断；worker class 更新为 current，调用完成后继续 staged refill。
- native worker 首次启动期间的 pending request 在两个 worker 全部 ready 后统一调度。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity 未变，本轮未修改 Rust/JNI 或 Kotlin。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.128 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK 与真机 native priority migration | Unverified-device |
