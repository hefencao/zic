# zic Implementation Plan

本文件只列未完成工作。

## P0：Android 运行模式身份设备闭环

- 在同一设备依次执行 debug/profile/release 的 `flutter run`，确认 package、versionName、versionCode 和签名链一致，切换模式不卸载、不清空应用数据。
- 记录 `dumpsys package dev.zic.zic` 与安装前后数据目录状态；若仍卸载，优先检查签名或 Flutter tooling 行为，不再把它归因于缓存。
- 版本发布时同时更新 pubspec 与 `android/zic-version.properties`；门禁必须拒绝不一致。

## P0：封面冷启动设备闭环

- 冷启动后记录首页/书架封面：memory hit、persistent file hit、legacy URL migration 和真实网络 miss 的数量与耗时。
- 同一漫画仅改变封面 URL/token 后，Widget/Future identity 应保持，稳定 `cover` key 应命中；不得创建并行封面缓存。
- 检查 durable file-backed image source 是否直接交给 decoder；若仍慢，继续拆分 manifest 打开、文件定位、image decode 和 UI mount，不扩张缓存层。

## P0：可信 E-Hentai 版本关系接入

- 在 E-Hentai/Venera 来源适配器中提供“旧 gallery/version ↔ 新 gallery/version”的可信关系和新旧 ChapterManifest；缓存层不使用标题或作者猜测。
- 对关系内页面运行 `VerifiedArtifactReusePlan`：优先 checksum，其次 `/s/<image-key>/`，最后唯一内容 hash。
- 新版本尚未写入权威正文时使用 alias；新版本提交后执行 rekey，验证旧 URL artifact 可被新精确 DownloadId 复用。
- 检查重复/缺失 image key、页序变化、插页和删除页，任何歧义页面必须保持 miss。

## P0：统一缓存与稳定 ID/key 审计闭环

- 维持唯一 `ResourceCacheCoordinator.responses` 和唯一 composition-owned `ArtifactCacheManager`；新增缓存必须先说明为何不能进入这两个 owner。
- 为原生、Mihon、Venera、本地来源逐项记录：实体 ID、canonical identity、章节 ID、资源角色 key、精确 artifact ID、revision 和 URL locator。
- 保持旧持久化 identity/DownloadId 格式兼容；新 key 使用版本化、长度前缀编码。迁移必须显式，不能静默全量失效。
- 检查 Venera 旧 opaque payload、历史书架记录、阅读进度和下载记录在新稳定 ID 下的 alias/兼容行为。

## P1：Reader 资源会话与纵向性能回归

- 继续验证 dev.134 同章资源会话 retention、fresh used texture、holder playback、7/3 与 7/5/3/2 合同。
- 使用设备 Timeline 验证稳定 page composition 与渐进 host warm；不得新增 Reader 私有图片缓存或竞争 scheduler。
