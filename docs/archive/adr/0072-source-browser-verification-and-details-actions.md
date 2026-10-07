# ADR 0072：来源浏览器完成边界、验证恢复与详情动作

- 状态：Accepted
- 版本：0.31.0-dev.88
- 日期：2026-08-02

## 背景

来源浏览首次请求可能由 Cloudflare challenge 阻断。旧实现同时存在三条竞争行为：runtime interceptor 创建不可交互的后台 WebView 并等待，Dart host 在 15 秒后超时，App 在 `openBrowser` 仅启动 Activity 后立即重试。用户尚未完成验证时重试已经发生，typed verification 无法到达 UI；历史 synthetic gallery 条目还可能继续显示为单章节，掩盖真实目录失败。

Android 同一应用的多个进程也不能在未隔离 WebView data directory 的情况下任意初始化 WebView/CookieManager。插件隔离进程已经使用 CookieManager，主进程再创建可见 WebView 可能因数据目录争用直接结束。

详情页还需要稳定的 `WebView → 迁移 → 插件设置` 操作顺序、可持续显示的刷新结果以及来源元数据搜索/复制交互。

## 决策

1. `network_bridge.openBrowser` 的 Future 以可见浏览器 Activity 关闭为完成边界。Android plugin 使用 `ActivityAware` 和 activity-result 生命周期，不以 Activity 启动成功作为验证完成。
2. 可见浏览器运行在 App 主进程。插件隔离进程必须在任何 WebView/CookieManager 使用前通过 `AndroidWebViewProcess.configureDataDirectorySuffix` 设置独立 data-directory suffix。
3. 浏览器将 Cookie/localStorage 快照写入 App 私有原子文件。插件 runtime 的共享 `AndroidCookieJar` 在请求前导入该快照；不得依赖跨进程 `CookieManager` 内存状态。
4. Cloudflare interceptor 只做 fail-fast challenge 识别并抛出稳定错误，不创建隐藏 WebView、不等待用户操作。Mihon ABI adapter 检查完整 cause 链并投影 `source-verification-required`；Domain 映射为 `ErrorCode.sourceVerificationRequired`。
5. 来源列表或详情收到 typed verification 后，App 打开可见浏览器，等待关闭，再失效对应缓存并重试。普通 timeout、DNS、离线或插件死锁不得猜测为 Cloudflare。
6. Mihon synthetic gallery 仅在 chapter capability 确实不存在且 page-list 预检非空时生成，并携带 revision identity。旧 revision synthetic 条目不得在真实目录失败时继续作为权威目录。
7. 详情 AppBar 的 action 顺序固定为作品网页、来源迁移、插件设置；作品网页使用地球图标。加入书架导致路由切换为本地详情后，composition 仍注入相同来源的网页和设置能力。
8. 下拉刷新数据仍由既有 reload facade 所有；Presentation 只保存 `refreshing/success/failure` 图标状态。成功绿勾、失败红叉持续显示，禁止另建数据状态来源。
9. 来源分类和标签点击只向当前来源页提交 query；当前不建立聚合搜索。长按进入局部多选状态，复制是显式 Presentation 命令。

## 所有权

- `network_bridge`：浏览器 Activity、activity result、WebView 进程隔离、Cookie/localStorage 快照。
- `plugin_host_bridge`：Mihon/Venera ABI 调用和 challenge 异常转译；不拥有可见浏览器 UI。
- `plugin_host`：稳定 runtime error、opaque comic URL 和 synthetic identity 的协议适配。
- `catalog/resource_cache`：来源能力装饰与缓存失效；decorator 必须保留可选 `ComicWebUriSource`。
- `apps/app`：路由组合、详情 actions、刷新结果图标、同源搜索命令和标签局部选择。
- Reader/Pipeline/downloads：本 ADR 不改变其 session、artifact、预取、decode 或 lane 所有权。

## 被否决方案

- interceptor 内自动创建隐藏 WebView。
- Activity 启动后立即刷新。
- 将所有 15 秒或其他 timeout 统一识别为 Cloudflare。
- 目录失败时保留或创建无版本 synthetic 单章。
- 详情页解析 Mihon/Venera opaque token。
- 为标签点击建立第二套聚合搜索缓存。
- 通过缩小 7/3、2/1 窗口或降低 5/3/2 lane 掩盖网络问题。

## 后果

验证恢复需要用户明确关闭浏览器后才重试，因此生命周期可预测，Cookie handoff 也有清晰的写入边界。插件隔离进程与主进程不再争用 WebView data directory。代价是浏览器 Activity 和平台 plugin 需要维护 activity-result 状态，并需在真机验证 Cloudflare 页面、返回、进程重建和配置变化。
