# dev.88 来源浏览器与详情交互审计

## 问题清单

### 编译错误

- `demo_home_source_compat.dart` 依赖 Dart 对无继承关系 capability interface 的交叉类型提升；Dart 3.12 不保证该提升。
- `transport` 两个 Stream 测试错误地向 `Stream.toList()` 传入 `growable`。
- `reader_runtime` 测试使用 `ContentKind`，却未声明 `transport` 测试依赖和导入。

### 产品错误

- `network_bridge.openBrowser()` 在 Activity 启动后立即完成，来源页在用户验证前就重新请求；Activity 又以 `NEW_TASK` 启动，浏览器返回链不属于当前 Flutter Activity。
- 加入书架后路由切换到本地详情，未继续注入作品 WebView 能力。
- 详情页没有直接进入当前插件设置的 action；WebView/迁移/插件 action 顺序未固定。
- 来源页的 Cloudflare challenge 被后台不可交互 WebView 吞掉，外层先以 15 秒 timeout 失败，无法投影 typed verification。
- 历史 synthetic 单章可在真实目录失败时继续作为本地详情的可见目录，造成“失败变单章节”的错觉。
- 默认 `RefreshIndicator` 完成后收回，无法保留成功/失败状态。
- 来源分类和标签不可直接搜索，也不能长按多选复制。

### 性能问题

- 后台 Cloudflare WebView 最长阻塞 30 秒，同时占用 plugin invocation permit；外层 timeout 后底层调用仍需退出。

### 测试错误

- 上述 `Stream.toList(growable:)` 和缺失 `ContentKind` 导入属于测试编译闭包错误；不得修改产品逻辑规避。

## 所有权清单

| 状态/资源/命令 | 当前所有者 | 正确所有者 |
| --- | --- | --- |
| 浏览器 Activity 打开与返回 | `network_bridge`，但无 Activity result 生命周期 | `network_bridge` ActivityAware plugin + Browser Activity |
| Cloudflare challenge 识别 | `network_bridge` runtime interceptor | 保持；只产生 typed/fail-fast 网络错误，不拥有 UI |
| 验证后重试时机 | 来源页在 MethodChannel 启动返回后立即重试 | App Presentation 等待 `network_bridge` 浏览器关闭后重试 |
| plugin invocation timeout | `plugin_host` limits 与 Android IPC 两个独立上限 | `plugin_host` 定义操作上限，Android IPC 只提供更宽 transport envelope |
| synthetic gallery | Mihon adapter | 保持；仅 capability 确实不存在且 page-list 非空时生成，并带版本 identity |
| 详情 action | App Presentation | 保持；只调用注入的 WebView、迁移和设置 facade |
| 来源设置 | 外部 source adapter + App route | 保持；详情不直接访问插件内部对象 |
| 标签搜索请求 | 详情 Presentation | 只产生查询命令；来源页拥有 query 和 browse 生命周期 |
| 标签多选 | 详情局部 UI 状态 | 保持；剪贴板写入由 Presentation 显式用户命令触发 |
| 下拉刷新结果图标 | 详情 Presentation | 保持；数据刷新仍由既有 reload facade 执行 |

## 被否决方案

- 继续让 interceptor 自动创建隐藏 WebView：用户无法交互，且与外层 timeout 竞争。
- Activity 启动后立刻刷新：必然发生在验证完成前。
- 将所有 timeout 猜成 Cloudflare：会误分类普通慢源、离线和插件死锁。
- 目录失败时继续展示或新建未版本化 synthetic 单章：隐藏真实错误。
- 为标签搜索新建第二套聚合搜索缓存：当前只回到同一来源页并复用其 query/cache owner。
- 在详情页直接解析 Mihon/Venera token 或重启 runtime：仍由 adapter/controller facade 处理。
- 为了通过测试改变传输 chunk 或 Reader/Pipeline 行为：测试编译错误应修测试。

## 实际修复

- 修复 Dart 3.12 capability 判断，显式保存 `ComicWebUriSource?`；修复两个 `Stream.toList()` 测试调用，并将 `ContentKind` 测试依赖归还 `transport`。
- `NetworkBridgePlugin` 改为 `ActivityAware + ActivityResultListener`，浏览器关闭才完成 MethodChannel Future；配置变化不错误关闭请求，宿主 Activity 真正 detach 时显式失败。
- 可见 `NetworkBrowserActivity` 留在 App 主进程；插件隔离 service 在创建 runtime driver 前调用 `AndroidWebViewProcess.configureDataDirectorySuffix("zic_plugin_runtime")`。
- Cloudflare interceptor 删除后台 WebView/等待，只在 403/503 + Cloudflare challenge 证据成立时 fail-fast；Mihon cause-chain 映射为 typed verification。
- 浏览器快照继续使用 App 私有原子文件；`AndroidCookieJar` 每次请求前导入匹配 origin 的最新 Cookie。
- Mihon host invocation timeout 调整为 45 秒，Android IPC 仅作为 65 秒 envelope；timeout 本身仍为普通 source failure。
- 来源页和详情页的恢复操作等待浏览器返回，再失效缓存并重试。封面、分页、详情和章节操作复用同一 typed failure。
- synthetic Mihon gallery identity 加入 `synthetic_revision=2`；App composition 过滤旧 revision，真实目录失败不能继续投影历史单章。
- `CachedBrowsableComicSource` 保留 `ComicWebUriSource`；本地/远程详情都注入作品 URL、插件设置和同源搜索，加入书架不丢失这些能力。
- AppBar action 顺序固定为地球 WebView、迁移、插件来源；插件来源显示名称并点击进入对应设置。
- 下拉刷新使用透明原生 indicator 触发，但由同一位置的 Presentation badge 持续显示旋转刷新、绿勾或红叉。
- 将刷新状态、来源 action、metadata 分组和标签选择从 2694 行 `comic_details.dart` 按 Presentation 交互所有权拆入 `comic_details_interactions.dart`；主文件约 2093 行，未增加循环 import 或全局状态。
- 来源分类和标签点击将 query 提交到当前来源页；长按进入多选，复制按原显示顺序输出。

## 删除或失效的冗余行为

- 删除 interceptor 创建的隐藏 WebView 和 30 秒验证等待。
- 删除浏览器 Activity 的独立插件进程声明；可见浏览器不再与 plugin runtime 混在同一进程。
- Activity 启动后立即成功返回的 MethodChannel 语义失效。
- 旧 synthetic revision 不再被视为当前有效目录。
- 详情页中旧的浏览器图标语义由 `open_in_browser` 统一迁为地球 `public`。
- 未新增聚合搜索 facade、详情私有缓存或新的插件设置状态。

## 验证结果

当前环境已通过 repository/Dart structure、library directive、Pipeline compile boundary、dev.75–dev.88 owner gates、Android dependency/Trace、Mihon entry/payload/ABI/split-classloader/read-only/chapter、Venera network/native/headers/preflight/bootstrap、source resource、Reader layout/demand/streaming、UI architecture、共享 browser Kotlin 提取编译、external source settings/login 和 native header 契约。

当前环境没有 Flutter/Dart/Gradle/Android SDK/Cargo，无法执行 analyzer、Dart/Flutter tests、APK/kernel snapshot、Gradle Android tests 和 Rust tests。浏览器不闪退、Cloudflare Cookie 恢复、刷新图标与标签手势仍需真机验证。
