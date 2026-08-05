# ADR 0118：统一应用版本、稳定缓存身份与已验证 Artifact 复用

**状态：Accepted**

## 背景

Android build type 虽共用 applicationId，但 versionCode/versionName 由 Flutter 命令行投影，debug/profile/release 可产生不同版本身份。设备已有更高 versionCode 或不兼容签名时，运行模式切换可能触发安装失败、降级处理或卸载重装，造成应用数据丢失。

缓存侧同时存在两个身份错误：

1. 封面响应和首页 Future identity 使用当前 URL；E-Hentai 等来源更新 token/URL 后，同一漫画会重新加载封面。
2. Venera opaque comic/chapter ID 包含标题、封面、简介、章节标题和 sequence；展示字段变化会改变实体 ID，并继续污染章节、页面和缓存 namespace。

Reader artifact 的精确 `DownloadId` 正确表示某一确定字节版本，但没有在“来源已证明新旧页面等价”后复用旧 artifact 的 alias/rekey 能力。

## 决策

1. Android debug/profile/release 读取同一 `zic-version.properties`，共用 applicationId、versionName 和 versionCode；不使用 build-type suffix。项目内 pubspec 与 Android 版本文件由门禁保持一致。
2. 实体 ID 只包含来源稳定 locator，不包含标题、封面、简介、排序位置或其他展示字段。
3. 封面等逻辑资源使用 `source + canonical comic + resource role` 作为稳定缓存 key；请求 URL 只负责 miss 后取数。
4. 旧 URL-derived image key 只允许单向读取迁移；新网络正文只写稳定 key，禁止同时维护两套权威缓存。
5. 保留现有精确 `DownloadId` 格式，避免令所有历史 Reader artifact 失效。
6. `ArtifactCacheManager` 增加有界 alias、链解析、循环保护和物理 rekey。新精确 key 写入正文后自动脱离 alias；删除 alias 不删除其 target。
7. 版本间页面复用只接受明确证据：相同 checksum、E-Hentai `/s/<image-key>/` 或唯一内容 hash。标题、作者、文件名或相同页码不足以证明等价；用户确认的漫画源迁移只为确实存在的旧 artifact 注册 alias。
8. 自动发现两个 gallery/version 属于同一作品不在缓存层猜测；必须由来源适配器、用户确认或已有迁移关系提供可信关联。
9. 统一缓存管理保持两个职责清晰的 composition owner：
   - `ResourceCacheCoordinator.responses`：封面、详情、章节元数据、搜索响应；
   - `ArtifactCacheManager`：Reader 不可变页面 artifact。
   不物理合并目录响应与大媒体 artifact，也不新增 UI 私有缓存。

## 后果

- 同一漫画封面 URL/token 改变时仍可命中稳定 cover key，App 启动不再因 locator 漂移强制重载。
- Venera 展示字段更新不会产生新的 comic/chapter identity；旧 opaque ID 仍可读取。
- 已验证的新旧页面关系可立即复用 memory/persistent artifact，并可在新版本提交为权威后物理 rekey。
- 未提供可信版本关系的 E-Hentai gallery 不会自动复用，避免错误图片污染。
- Android 三种运行模式共享版本身份；外部使用不同签名的 APK 仍不能原位覆盖，这不是版本号能够解决的问题。

## 取代关系

- 不取代 Reader `DownloadId`、partial、session、decode、texture 所有权 ADR。
- 补充现有 catalog canonical identity 与 source migration 规则。
- 不改变 ADR 0117 的 Reader 资源会话 retention。
