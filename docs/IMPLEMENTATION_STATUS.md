# zic Implementation Status

**源码版本：** `0.31.0-dev.135`
**App build：** `0.31.0+135`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=135`，且无 applicationId/versionName suffix；当前三种模式继续使用同一项目签名链。
- 封面、详情、章节元数据和搜索响应继续由唯一 `ResourceCacheCoordinator.responses` 管理；Reader 不可变页面 artifact 继续由唯一 composition-owned `ArtifactCacheManager` 管理。
- 目录响应缓存与 Reader artifact 不物理合并；二者通过统一的稳定身份合同区分“实体 ID / 资源角色 / 精确字节版本 / 已验证复用 alias”。
- 封面缓存按 `source + canonical comic + cover role` 命中，请求 URL 只用于 miss 后的真实加载；旧 URL key 可单向迁移到稳定 key。
- 首页封面 Future identity 不再混入可变 URL/token，同一漫画封面 locator 更新不会强制重建请求。
- Venera comic/chapter ID 新格式只编码稳定 raw locator，不再包含标题、封面、简介、章节标题或 sequence；旧 opaque payload 仍可读取。
- `ArtifactCacheManager` 支持有界 alias、链解析、循环拒绝、alias invalidation 和物理 rekey；精确 `DownloadId` 格式不变。
- `VerifiedArtifactReusePlan` 只用 checksum、E-Hentai `/s/<image-key>/` 或唯一内容 hash 建立版本间页面复用；用户确认的漫画源迁移会仅为确实存在的旧 artifact 注册 alias，不按标题、作者或页码猜测。
- 自动发现“两个 E-Hentai gallery/version 属于同一作品”的可信关系尚未实现；必须由来源适配器或显式迁移流程提供后才应用 alias/rekey。
- Reader 资源会话 retention、holder playback、7/3 下载窗口、7/5/3/2 水位、两个 decode worker、单 blit Android output 与 partial source-growth 保持。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity：`zic-media-core-dev134-abi6-lib00121400`（本轮无 Rust/JNI 变更）。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.135 ownership gates | Verified-static |
| Venera JavaScript bootstrap stable-ID contract | Verified-toolchain |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android debug/profile/release install-switch behavior | Unverified-device |
| App cold-start cover latency/cache-hit behavior | Unverified-device |
| E-Hentai real version relation discovery and artifact reuse | Partially implemented：复用原语已完成，可信关系发现尚未接入 |
