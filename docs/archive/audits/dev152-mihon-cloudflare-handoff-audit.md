# dev.152 Mihon Cloudflare handoff 审计

## 复现

WebView验证后，replacement Mihon runtime 对 `https://18comic.vip/albums?o=mv&page=1`再次返回 typed `sourceVerificationRequired`。堆栈已经位于新 adapter 的 browse，不再是 dev.151 的 closed-session错误。

## 根因

- browser snapshot跨进程写入后，接收 runtime通过 `CookieManager.setCookie()`镜像，再立即从 CookieManager读取作为首个 OkHttp请求 cookie，存在异步写入竞争。
- 恢复入口没有使用 typed failure中的原始失败 URL。
- 浏览器关闭曾可被当成成功边界，无法证明获得了新的 `cf_clearance`。
- 没有区分“请求根本没有 clearance”和“请求已经带 clearance但仍被 Cloudflare拒绝”，后者继续自动 fallback会形成验证循环。

## 修复

- snapshot cookie同步进入 Mihon `AndroidCookieJar`内存 map；CookieManager降级为兼容镜像。
- typed error details传递 request URL/status/clearance存在性。
- Cloudflare模式打开失败 URL，删除旧 clearance并等待新 token。
- 已携带 clearance仍被挑战时禁止自动 WebView fallback。
