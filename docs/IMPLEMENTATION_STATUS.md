# zic Implementation Status

**源码版本：** `0.31.0-dev.137`
**App build：** `0.31.0+137`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=137`。
- 首页先发布章节投影和 SavedComic primary 数据，封面组件不再等待分类、偏好、阅读状态及默认值补写。
- catalog metadata response 使用结构化 byte-weight；`ResourceCacheCoordinator.responses` 继续唯一拥有 metadata/cover response cache。
- Reader page artifact 继续由 composition-owned `ArtifactCacheManager` 管理；不新增 App/Reader 私有正文缓存。
- 普通远程 transport chunk 首批约 16 KiB、后续约 64 KiB 后进入 DownloadSession/artifact/native source，避免一万余次细碎 append。
- current 远程 producer 只在启动、waitingSource 或 decode depth≤1 时让同源背景传输等待下一块；depth≥3 即恢复。7/3、7/5/3/2、全局 5、decode 3、upload 2、remote bucket 5 保持。
- Reader 资源会话 retention、holder playback、单 blit Android output、partial source-growth 和稳定缓存身份保持。
- Native identity：`zic-media-core-dev134-abi6-lib00121400`（本轮无 Rust/JNI 变更）。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.137 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| 首页 first-cover 与远程 current flow-pressure | Implemented；待设备复验 |
