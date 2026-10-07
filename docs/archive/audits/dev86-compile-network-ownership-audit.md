# dev.86 编译闭包与共享网络所有权审计

## 问题清单

### 编译错误

- `apps/app/lib/comic_details.dart` 声明 `ComicDetailsSourceWebViewOpener?` 字段但未定义 typedef。
- `apps/app/lib/source_browser.dart` 通过 `details.ComicDetailsSourceWebViewOpener` 引用同一缺失类型，形成四处 analyzer/kernel 阻断。
- 新增 package 若不加入 workspace、依赖白名单和 analyzer/test runner，会形成只在 App build 暴露的组合漏检。

### 产品错误

- dev.85 的 WebView 恢复入口功能方向正确，本轮未发现需要改变章节失败/synthetic 判定的产品逻辑。
- Mihon 专属命名 `openMihonLogin` 被 Venera 设置页复用，表达了错误所有权并阻碍原生来源复用。

### 性能问题

- 本轮未改变正文网络或 256 KiB I/O；没有通过降低预取窗口、lane 或关闭 Cloudflare 自动恢复规避问题。
- 通用网络 helper 迁移后仍复用同一 OkHttp/CookieManager，未新增请求、缓存或完整字节复制。

### 测试错误

- dev.85 静态门禁只检查字段存在，没有检查 callback typedef，未捕获真实 Dart 编译闭包。
- 登录 Kotlin 提取编译固定指向 plugin-host 文件路径，迁移 owner 后必须同步迁移测试，而不是保留假 facade。
- dev.85 登录快照使用 SharedPreferences 跨进程交接，测试只验证编译而未验证进程缓存语义；dev.86 改为原子文件并新增静态契约。

## 所有权清单

| 状态/资源/命令/生命周期 | dev.85 当前所有者 | dev.86 正确所有者 |
|---|---|---|
| 详情 WebView callback 类型 | 漏定义 | App Presentation API，仅定义命令签名 |
| 来源 WebView Activity 生命周期 | `plugin_host_bridge/MihonLoginActivity` | `network_bridge/NetworkBrowserActivity`，由 App composition 直接调用 |
| Cookie/localStorage 登录快照 | `ExternalLoginSnapshotStore` | `network_bridge/NetworkBrowserSnapshotStore`，不经 `ExternalPluginController` 转发 |
| 浏览器进程选择 | network package 硬编码 plugin process | App manifest placeholder 组合；network package 提供独立默认值 |
| 跨进程 snapshot 交接 | SharedPreferences | App 私有文件临时写入 + rename 原子替换 |
| Dart 平台浏览器 facade | Mihon metadata reader | `AndroidNetworkBridge` |
| Cloudflare challenge | plugin-host Mihon runtime common | `network_bridge/AndroidCloudflareInterceptor` |
| OkHttp CookieJar | 两份 Mihon ABI 私有实现 | `network_bridge/AndroidCookieJar` |
| DNS fallback | plugin-host Mihon runtime common | `network_bridge/FallbackDns` |
| Mihon `NetworkHelper` ABI 包名 | plugin host | plugin host ABI adapter，内部消费 network bridge |
| 插件 trust/session/cancel/close | plugin host | plugin host，不迁移 |
| request/response/range/body 流 | transport/downloads/pipeline | 保持原 owner |
| rhttp/native HTTP backend | 尚不存在 | 未来共享 transport/network composition，非 plugin host |

## 被否决方案清单

- 仅添加 typedef，不处理通用网络所有权：会继续把原生来源能力绑死在插件桥。
- 在 App/详情页直接调用 CookieManager 或 WebView：违反 Presentation/API 泄漏边界。
- 原生来源复制 Cloudflare/Cookie/DNS：制造两个权威网络实现和行为漂移。
- 将 plugin trust/session 搬进 network bridge：造成通用低层反向依赖插件高层。
- 直接引入 rhttp 并绕过现有 transport/Pipeline：形成竞争 DownloadSession/artifact 平面。
- 以兼容 facade 保留 `openMihonLogin`：生产已有完整迁移，应删除旧命名而不是双入口。
- 继续硬编码 `:zic_plugin_runtime` 或依赖 SharedPreferences 跨进程刷新：把运行时耦合藏在新 package 内，仍不是真正迁移。

## 删除内容

- `plugin_host_bridge/android/.../MihonLoginActivity.kt`
- `plugin_host_bridge/android/.../ExternalLoginSnapshotStore.kt`
- `plugin_host_bridge/android/.../RuntimeCloudflareInterceptor.kt`
- `plugin_host_bridge/android/.../FallbackDns.kt`
- plugin-host MethodChannel 的 `openMihonLogin`、`readExternalLoginSnapshot`
- `ExternalPluginController.openSourceWebView`、`readSourceWebViewSnapshot` 通用网络转发
- `AndroidMihonApkMetadataReader` 中的登录 snapshot 类型和方法
- Mihon 1.4/1.6 各自重复的私有 `AndroidCookieJar`

## 验证

- 通过 repository/Dart structure、directive order、dev.75–dev.86 owner gates。
- 通过共享 network browser Activity/store Kotlin 提取编译。
- 通过 Mihon ABI routing、entry、payload Context、classloader、chapter 与 read-only 契约。
- 通过 Venera network/bootstrap/response/preflight、Reader/Pipeline/UI/source binding 等当前环境可执行契约。
- 未执行 Flutter analyze/test 或 Android build：当前环境无 Flutter/Dart/Android SDK/Gradle。
