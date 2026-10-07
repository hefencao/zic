# dev.87 Cloudflare、详情元数据与本地 artifact 审计

## 问题清单

### 编译错误

- `PluginHostBridgePlugin.kt` 使用 `Bundle` 读取 metadata，但缺少 `android.os.Bundle` 导入。
- dev.86 门禁覆盖网络拆包，却未覆盖该文件的 Android 类型闭包。

### 产品错误

- 来源首页/分页在进入详情前也可能被 Cloudflare 拦截；封面失败此前只显示破图。
- Cloudflare challenge 没有跨 operation 的稳定 domain 状态，页面 fallback 不完整。
- 详情已有下拉刷新，右上角刷新命令重复；WebView 应访问作品详情页。
- 来源 category/tag 与用户书架分类混在同一区域，author namespace 重复显示。
- 来源切割条漫后，单页比例看似普通，旧 model v4 缺少常见 long-strip 英文标签并可能保留错误 LTR profile。

### 性能问题

- trace 含 7181 条事件。16 次可计时的本地 `content://` artifact-cache/session-copy 中位吞吐约 5.47 MB/s。
- 同一 5.6–20.0 MB 页面出现两次持久 artifact 恢复，单次约 0.87–4.96 秒。
- 代码路径先 `Artifact.restore()` 完整 CRC 扫描，再 `readArtifact()` 二次整文件读取；256 KiB 平台 chunk 不是主要等待点。

### 测试错误

- 旧 dev.83/dev.84 门禁将 adaptive model 版本和 `_ExpandableTagRow` 旧调用形式写死，阻止合法迁移。
- 缺少来源首页、封面 Cloudflare fallback、metadata 分区、作品 WebView 和 promoted metadata restore 回归。

## 所有权清单

| 状态/资源/命令/生命周期 | 修复前 | 正确所有者 |
|---|---|---|
| Cloudflare challenge 判定 | Mihon interceptor 错误文本、页面零散处理 | network helper 产生 cause；plugin runtime 归一代码；domain typed error |
| 来源 WebView 命令 | 详情 Mihon 条件入口 | App composition 的 `AndroidNetworkBridge`，所有 remote source 可注入 |
| 作品网页 URI | App 直接调用 Mihon token helper | `catalog.ComicWebUriSource` capability；plugin adapter 解析 opaque identity |
| 来源分类/标签 | 详情同一 tags 行 | catalog Comic metadata；Presentation 只分组显示 |
| 书架分类 | 与 source tags 混排 | catalog/library preference 与 LibraryCategory |
| adaptive profile | model v4 持久值 | `reader_runtime` model v5，metadata fingerprint/profile version 驱动重评 |
| promoted artifact 完整性 | 每次 foreground 命中完整 rehash | storage 默认完整校验；持久 cache read 可用原子 metadata/长度快速恢复 |
| page bytes/session/artifact | downloads + sessions + pipeline | 保持不变；App/Reader 无私有 LRU 或直读旁路 |
| libwebp source | 远程 fetch 失败 | 用户文件库的 1.6.0 只作为本地验证输入，不并入仓库 |

## 被否决方案清单

- 未进入详情就不处理 Cloudflare：来源列表仍不可用。
- 按任意“network”错误显示 WebView：会把 DNS、离线和解码错误误分类。
- 自动弹出 WebView：多个并发封面失败会产生侵入式导航；改为明确图标。
- 保留详情刷新按钮并新增 WebView：形成重复命令；下拉刷新已是权威更新入口。
- App/Presentation 解析 Mihon/Venera Base64 token：泄漏插件协议。
- 仅按页面高度/宽度判断条漫：来源切片后证据失真。
- 清除所有用户阅读方向或强制 vertical：覆盖显式用户设置。
- 绕过 Pipeline 直接读取本地文件、关闭预下载或降低并发：建立竞争实现或掩盖慢点。
- 所有 artifact 永久跳过 checksum：破坏 partial/resume 和外部损坏检测。

## 删除和迁移

- 删除未再使用的 `comicDetailsRefreshKey`。
- 详情正常态移除右上角刷新 action；保留下拉刷新和失败首屏 retry。
- App 的 Mihon 专属作品 URL 判断迁为通用 `ComicWebUriSource` capability。
- dev.83/dev.84 静态门禁更新到当前合法 API，未删除其历史所有权检查。

## 验证

- repository/Dart structure、directive order、Pipeline compile boundary、dev.75–dev.87 gates 通过。
- Android dependency、Trace、共享 network browser Kotlin 提取编译通过。
- Mihon entry/payload/ABI/classloader/read-only/chapter contract 通过。
- Venera policy/native/response/preflight/bootstrap、source binding、Reader/Pipeline/UI contracts 通过。
- 使用用户文件库中的 libwebp 1.6.0 源码，host source build 和 incremental/loop fixtures 通过。
- 当前环境无 Flutter、Dart、Gradle、Android SDK 和 Cargo；对应 analyze/test/build 未执行。
