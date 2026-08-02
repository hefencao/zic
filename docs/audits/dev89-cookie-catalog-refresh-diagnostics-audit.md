# dev.89 Cookie、目录、刷新与诊断审计

## 补充闭环

- 审查发现远程详情下拉刷新仍直接调用 `source.loadComic`，绕过 App composition 的持久目录回归门禁，足以产生“刷新绿勾但页面退回 synthetic 单章”。已删除该竞争路径，`ComicDetailsLibrarySnapshot` 携带组合层确认的 `sourceComic/sourceChapters`，详情只消费原子刷新结果。

## 问题清单

### 编译错误

- 新增 source browser UA 协议后，所有 descriptor 构造保持可选参数兼容；网络桥 Dart/Kotlin 方法、测试 stub 与旧门禁同步迁移。
- Mihon 1.4/1.6 `AndroidCookieJar` 构造改为注入 UA provider，所有 ABI 调用方一次完成迁移。

### 产品错误

- 可见 WebView 默认 UA 与 Mihon/Venera HTTP UA 不一致，Cloudflare clearance 可能在一分钟内再次失效。
- 详情初始化刷新运行时，用户下拉刷新直接得到 `false`，导致真实目录已更新却显示红叉。
- 插件设置 action 使用带文字 TextButton，与 WebView/迁移 IconButton 风格不一致。
- Mihon 任意 UOE 被当作目录能力缺失，可在验证/解析失败时错误创建 synthetic 单章节。
- 已保存真实目录可能被后续 synthetic-only manifest 覆盖。

### 性能问题

- 本轮未修改 Reader/Pipeline、下载窗口、解码、上传或本地 artifact 性能路径。
- Cookie 快照只在请求前读取一个有界小文件；不复制 WebView 数据库，不建立新缓存平面。

### 测试错误

- dev.85–dev.88 静态门禁仍固定旧 CookieJar 构造、revision 2 或直接 snapshot 读取，已迁移到当前共享 importer 和 revision 3。
- 共享浏览器 Kotlin 提取测试的 WebSettings stub 缺少 userAgent getter/setter，已补齐。
- 新增受控 Future 测试，验证初始化刷新和下拉刷新合并、仅调用一次 source，并验证结果图标 2 秒后消失。

## 所有权清单

| 状态/资源/命令 | 当前正确所有者 | 说明 |
|---|---|---|
| 可见 WebView Activity | `network_bridge` | App 主进程，等待 Activity result 后完成 Future |
| 来源浏览器 URL + UA | `ComicWebViewRequestSource` / source adapter | 原子能力值，App 只转发 |
| Cookie/localStorage 快照 | `network_bridge` | 同站点、时效有界、原子文件 |
| Android Cookie 导入 | `AndroidBrowserCookieSession` | 唯一跨进程 handoff；不记录 Cookie 值 |
| Mihon 请求 Cookie | Mihon `AndroidCookieJar` | 请求前消费共享 importer |
| Venera 请求 Cookie | `VeneraNativeBridge` 的进程内 CookieManager | HTTP/Network.getCookies 前消费共享 importer |
| Dart 原生源 Cookie | 各 source 的 network/transport composition | 当前 MangaDex 无登录；不得经插件桥 |
| 详情刷新 in-flight | 详情 State | 同一 Future 为唯一进行中状态 |
| 刷新结果图标 | `comic_details_interactions.dart` | 2 秒 timer，Presentation 局部状态 |
| 真实目录证据 | Mihon runtime + App saved catalog | runtime 防同生命周期退化，App 防跨重启覆盖 |
| synthetic identity | `plugin_host`/Mihon adapter | revision 3；Presentation 不解析 token |
| 诊断 Trace | 现有 `DebugTraceLog` | App 只投影阶段、数量、耗时、错误码和脱敏摘要 |

## 被否决方案清单

1. **所有进程共用一个 WebView data directory**：Android 多进程 WebView 不支持，可能产生锁冲突、初始化崩溃或数据损坏。
2. **只复制 Cookie、不统一 User-Agent**：Cloudflare clearance 可能绑定 UA，已证明短时失效。
3. **遇到任意 UOE 就认定无章节能力**：扩展解析器也可能抛 UOE，会错误创建 synthetic 单章。
4. **刷新已在运行时返回 `false`**：把生命周期状态误投影为业务失败，造成章节成功但红叉。
5. **用 synthetic 单章节维持“成功”界面**：掩盖 Cloudflare/目录失败并覆盖真实章节，禁止。
6. **Trace 输出完整 Cookie、localStorage 或插件 token**：高敏且高频，禁止；只记录名称、数量、长度或摘要。
7. **App/Reader 直接读取 CookieManager 或插件内部对象**：破坏 network/plugin 所有权，不采用。

## 删除与迁移

- synthetic current revision 2 失效，迁移为 revision 3。
- 插件设置 AppBar action 从 TextButton 迁移为 IconButton。
- `AndroidCookieJar` 内部重复 snapshot 导入代码迁移到共享 `AndroidBrowserCookieSession`。
- 旧 dev.85–dev.88 门禁中固定实现字符串同步更新；未删除生产文件。

## 未验证项

当前容器若仍无 Flutter/Dart/Gradle/Android SDK，则无法执行 analyzer、Flutter test、APK/kernel snapshot 和真机 Cloudflare。必须在 Android 设备上验证同一作品完成 challenge 后 1、5、15 分钟的目录稳定性，并在失败时导出新 Trace。
