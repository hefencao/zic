# zic Implementation Status

**源码版本：** `0.31.0-dev.136`
**App build：** `0.31.0+136`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=136`，无 applicationId/versionName suffix。
- `CachedBrowsableComicSource` 为 search results、comic details 和 chapter metadata 提供结构化 byte-weight；唯一 `ResourceCacheCoordinator.responses` 继续拥有容量、TTL、LRU 和 in-flight join。
- 封面、详情、章节元数据和搜索响应由唯一 response cache 管理；Reader 页面 artifact 由唯一 composition-owned `ArtifactCacheManager` 管理，二者不物理合并。
- 封面缓存继续按 `source + canonical comic + cover role` 命中；Venera 新 opaque identity 不编码标题、封面或章节展示字段。
- artifact alias/rekey 与 `VerifiedArtifactReusePlan` 只使用 checksum、E-Hentai image key 或唯一内容 hash；不按标题、作者、页码猜测。
- Reader 资源会话 retention、holder playback、7/3 下载窗口、7/5/3/2 水位、两个 decode worker、单 blit Android output 与 partial source-growth 保持。
- App 中无调用的 local WebP-folder/local image-folder compatibility facade 已删除；文件夹图片导入由 `local_media`/`local_media_ui` 所有，单文件 WebP API 保留。
- 正式交付不包含 `.zic-workspace.json`，patch 不触碰本地 patch_dir。
- Android native build identity：`zic-media-core-dev134-abi6-lib00121400`（本轮无 Rust/JNI 变更）。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| dev.75–dev.136 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| 用户环境中报告的 catalog 编译错误 | Implemented；待用户 Flutter toolchain 复验 |
| Android debug/profile/release install-switch behavior | Unverified-device |
| E-Hentai real version relation discovery and artifact reuse | Partially implemented：可信关系发现尚未接入 |
