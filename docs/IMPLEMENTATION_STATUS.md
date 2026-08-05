# zic Implementation Status

**源码版本：** `0.31.0-dev.139`
**App build：** `0.31.0+139`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0` 和 `versionCode=139`。
- 首页先发布章节投影与 SavedComic primary 数据，封面不等待分类、偏好和阅读状态 enrichment。
- catalog response cache 使用稳定 source/comic/chapter identity 和结构 weight；页面正文不进入该缓存。
- ArtifactCacheManager 默认热字节 10 项/256 MiB，支持持久 backend、verified alias/rekey 和 foreground read join。
- Reader encoded window 为前 7/后 3；decode 角色为前 2/后 1；动态 holder 最大水位为 7/5/3/2。
- transition 覆盖率达到阈值后独立取得一帧，再恢复 current/neighbor staged refill；不存在 DownloadFlowGate、startup-buffer 或 holder-depth 网络资格门控。
- 页面网络由共享 NetLane 唯一调度：normal 5、current 高优先级保留槽 1、priority migration/preemption；local bucket 2、remote bucket 5。
- DownloadJob 首批约 16 KiB、后续约 64 KiB 合并 transport 小块；partial/resume、source growth 和 WebP prefix hints保持。
- holder-driven playback 在 successor 缺失时保持当前 output，使用 one-shot deadline wake；两个 decode isolate常驻，current 后续最多双帧批次。
- Android output 使用默认 platform channel、单 blit lane和普通 main-thread post；used texture 不跨 Reader 复用。
- Reader 资源会话最多保留 1 个 idle chapter、TTL 2 分钟；保留 resource session，释放 Reader binding、projection、playback wake 和 used texture。
- Native identity：`zic-media-core-dev134-abi6-lib00121400`；本轮不修改 Rust/JNI。
- 核心文档已按 production code 重新对齐，最新综合决策见 ADR 0122。

## 当前开放问题

- 目标设备仍需验证 transition 首帧、远程 WebP frame cadence、后台重入和首页首封面时序。
- Flutter analyzer、Dart/Flutter owner tests、Android APK 构建和真机生命周期验证未在当前环境执行。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| current-code documentation consistency gate | Verified-static |
| dev.75–dev.139 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android debug/release APK | Unverified：当前环境无完整工具链 |
| 设备性能与生命周期 | Implemented；待设备复验 |
| Verified-device | 无新增结论 |
