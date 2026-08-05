# zic Implementation Status

**源码版本：** `0.31.0-dev.138`
**App build：** `0.31.0+138`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=138`。
- 首页先发布章节投影和 SavedComic primary 数据；封面不等待 enrichment。
- transport 小块首批约 16 KiB、后续约 64 KiB 后进入 DownloadSession；partial/resume 保留。
- dev.137 的同 source bucket `DownloadFlowGate` 已完全删除；DownloadJob 不读取页面角色，目标页网络不受 current holder depth 控制。
- Current 网络优先由 composition-owned NetLane 的 high-priority reserved slot、priority migration 和 preemption 唯一负责。
- target coverage 达 0.15 后成为 transition；transition depth=0 时独立执行 `t>0` 首帧，之后才恢复 c/n/m/p staged 水位。
- 7/3 encoded window、7/5/3/2 decode 水位、全局 5、decode 3、upload 2、remote bucket 5 保持。
- Reader 资源会话 retention、holder playback、单 blit Android output、partial source-growth 和稳定缓存 identity 保持。
- Native identity：`zic-media-core-dev134-abi6-lib00121400`（本轮无 Rust/JNI 变更）。
- 正式交付不包含 `.zic-workspace.json`，Patch 不触碰本地 patch_dir。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.138 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| 设备切页行为 | Implemented；待设备复验 |
