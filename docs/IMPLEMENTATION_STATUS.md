# zic Implementation Status

**源码版本：** `0.31.0-dev.125`
**App build：** `0.31.0+125`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 下载前 7 / 后 3、current handoff、全局/remote 5、本地稳定 2 与启动 local=1 保持。
- 动画 staged 7/5/3/2、静态一帧满足、30 帧 partial loop 与 retained transfer/output 保持。
- Android texture pool 可按完整 DecodeId 保留最后 platform frame；新 Reader 可先恢复该 output，正常 decode 在后台继续并替换。
- 未封缄 native decode failure 归一为 `NeedMoreData`；协调器等待 source revision，不进入定时 recovery。
- `.zic-workspace.json` 为本地可选配置，发行 ZIP 和 patch 均不包含；`ZIC_PATCH_DIR` 可覆盖。
- 纵向 page-shell、geometry snapshot、渐进 host warmup 与 FrameBudget 保持。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Python static gates | Verified-static |
| Android texture Kotlin redraw | Verified-static |
| retained restore / partial source owner tests | Unverified：当前环境无 Flutter SDK |
| pinned libwebp host build/smoke | Verified-toolchain |
| Android APK / 后台恢复 | Unverified-device |
