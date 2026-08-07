# dev.153 Mihon Cloudflare 验证状态机审计

## 输入证据

- dev.152唯一基线。
- 设备错误报告：可见浏览器返回 `network-browser-cancelled`，随后 replacement runtime仍以 HTTP 403报告 `cf_clearance=absent`。
- 当前 Mihon `CloudflareInterceptor`：只在 Cloudflare 403/503且页面存在 `challenge-error-title`/`challenge-error-text`时把响应当作可通过 WebView解决的 challenge；普通 access/geo block不会进入该流程。

## 根因

1. ZIC detector把 `challenge-platform/cf-chl-*`脚本本身当成强 challenge证据，范围比 Mihon宽，会把 WebView中根本没有验证码的 403误映射为 `sourceVerificationRequired`。
2. dev.152验证浏览器先删除旧 `cf_clearance`并要求产生新 token；当 WebView直接正常打开时，不会产生新 token，因此无法完成。
3. `NetworkBrowserSnapshotStore.begin()` 打开浏览器时立即覆盖旧 snapshot；取消/失败尝试会把已有 handoff提前清空。
4. 自动 fallback guard只记录自动 WebView。用户手动验证一次后，下一次刷新仍有资格自动跳 WebView。

## 修复

- detector改为 Mihon交互 challenge DOM边界，保留 `cf-mitigated: challenge`明确协议证据。
- 浏览器不预删 Cookie；页面没有 challenge DOM时直接 capture并完成。
- begin保留兼容旧 snapshot，空 capture不覆盖已有非空 Cookie。
- 手动/自动浏览器都记录 guard；成功 browse才清除。
- 两处详情 WebView named callback与 typedef重新对齐。

## 被否决方案

- 不继续增加 WebView自动打开次数。
- 不把 `cf_clearance`缺失本身当成“必须验证”的充分条件。
- 不清空 CookieManager/全局 Cookie后再尝试。
- 不恢复隐藏 WebView或 30秒阻塞 interceptor。
