# ADR 0137：Mihon Cloudflare Cookie 同步交接与重复验证保护

**状态：Accepted**

## 背景

dev.151 已解决 WebView 验证后继续调用关闭 runtime session的问题，但新 runtime 的首次请求仍可能立即收到严格 Cloudflare 403 challenge。原 handoff 将 snapshot cookie 调用 `CookieManager.setCookie()` 后马上由 OkHttp `CookieJar` 读取；Android WebView CookieManager 的写入回调具有异步边界，因此跨进程恢复不能假设首个 HTTP重试已看到新 clearance。同时恢复页此前只使用 source website，而 typed错误已经知道真正失败的 URL。

## 决策

1. `SourceVerificationRequiredException` 结构化携带 request URL、HTTP status和请求时 `cf_clearance`存在性，通过 runtime envelope与 `Failure.details`传到 Presentation。
2. Cloudflare验证浏览器打开实际失败 request URL。进入验证模式前删除当前 clearance，并等待新的非空 `cf_clearance`；未得到新 token或用户关闭页面时验证不成功。
3. Mihon `AndroidCookieJar`直接读取匹配 host/UA 的浏览器 snapshot，并同步写入进程内 cookie map。首个 OkHttp重试从该 map生成 Cookie；`CookieManager`只做 WebView与兼容镜像，不作为首请求时序权威。
4. 如果运行时请求已经携带 `cf_clearance`仍收到严格 challenge，自动 fallback停止。页面保留错误和手动 WebView入口，防止“请求→WebView→请求”的无限循环。
5. Venera既有 process-global snapshot import保持兼容，不将 Mihon的新同步内存 map扩散为第二套 response cache。

## 后果

- WebView正常显示不再等价于验证完成；只有得到新的 clearance才会自动重试。
- 首个 Mihon请求不依赖 CookieManager异步完成时机。
- 若 clearance与 UA/IP/站点策略不兼容，用户会看到明确“已有 clearance仍被拒绝”而不是不断自动跳入 WebView。
