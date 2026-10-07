# dev.135 缓存身份与封面启动审计

## 范围

本轮严格基于 dev.134，参考 VibeVenera 的缓存复用实现，处理：

1. debug/profile/release 统一 Android applicationId、versionName、versionCode；
2. App 启动后的漫画封面缓存命中与加载；
3. E-Hentai 等“同一漫画更新版本 URL 改变”场景下的显式缓存复用；
4. 审计统一缓存管理与稳定 ID/key。

## 当前证据

### Android 版本身份

`apps/app/android/app/build.gradle.kts` 使用 `flutter.versionCode/versionName`。applicationId 没有 build-type suffix，但命令行 build-number 仍可令不同运行模式产生不同 versionCode。设备上存在更高 versionCode 或不同签名时，`flutter run` 可能卸载/重装，数据因而丢失。

### 封面缓存

封面响应由 composition-owned `ResourceCacheManager` 管理，但 key 的 identity 使用封面 URL。只要同一漫画的封面 URL 变化，就会作为新资源重新下载。首页 `_coverRequestIdentity` 也拼入了可变 cover source，导致 Widget/Future 被重新创建。

### Venera ID

当前 Venera comicId 的 opaque payload 包含 title、subtitle、cover、description；chapterId 又包含 title 和 sequence。这些展示字段变化会改变实体 ID，并继续污染 pageId 和缓存 namespace。这违反稳定实体身份要求。

### Reader 页面缓存

`ArtifactCacheManager` 以完整 `DownloadId` 作为权威 artifact key，符合精确字节版本身份，但当前没有 alias/rekey。不同 E-Hentai gallery/version URL 会生成不同 DownloadId，无法在已验证页面映射后复用旧 artifact。

### VibeVenera 参考

VibeVenera 不通过标题猜测版本关系。它维护显式 alias/rekey：新版本 page key 只有在版本关系和页面映射被确认后，才解析到旧版本缓存；正式写入新 key 后解除 alias。alias 链有循环保护。

## 所有权结论

“统一缓存管理”不等于把所有缓存合并为同一存储：

- 封面、详情、章节元数据和搜索响应：`ResourceCacheCoordinator.responses`；
- Reader 不可变页面 artifact：composition-owned `ArtifactCacheManager`；
- 下载中 partial、native source、decoded frame、texture：仍由既有 session/pipeline 层负责。

本轮只增加统一 key 合同和显式 artifact alias/rekey，不创建 UI 私有缓存或第二套 page cache。

## 稳定 ID/key 分层

- **实体 ID**：只包含来源稳定 locator，不含标题、封面、简介、排序位置等可变展示字段；
- **资源角色 key**：如同一漫画的 `cover`，不把临时 URL 当成实体 identity；
- **精确 artifact ID**：保留 source revision + canonical URI，表示某一确定字节版本；
- **复用 alias**：只有来源适配器或迁移流程提供已验证映射时，允许新 artifact key 指向旧 artifact key。

## 拒绝方案

- 不用标题/作者近似匹配自动复用 E-Hentai 页面，避免错图；
- 不修改现有 `DownloadId.key` 格式，避免全量失效历史 artifact；
- 不把 Reader page artifact 并入响应缓存；
- 不通过扩大无界内存缓存掩盖 key 不稳定；
- 不把 release/debug 签名差异伪装成版本号问题；统一版本只能避免版本身份漂移，外部不同签名 APK 仍不兼容。

## 验证清单

- Android 三种 build type 读取同一项目版本文件，且无 applicationId/version suffix；
- Venera 新 comic/chapter ID 不含展示字段，旧 payload 仍可解码；
- 封面 key 和 Widget request identity 不随 URL 改变；
- raw locator 仍只用于实际请求；
- artifact alias 支持 memory/persistent lookup、链解析、循环拒绝、写新 key 后脱离 alias、仅删除 alias 不误删 target；
- E-Hentai 风格不同 URL/DownloadId 在显式映射后可复用旧缓存；用户确认的漫画源迁移仅对实际存在的旧 artifact 注册 alias；
- 全仓没有新增并行封面缓存或 Reader 私有 page cache。
