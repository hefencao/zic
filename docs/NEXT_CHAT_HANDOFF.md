# dev.89 handoff

唯一后续基线：`zic_v0.31.0-dev.89_cookie-session-catalog-refresh-trace.zip`。不得混入 dev.88 或更早候选。

## 本轮关键所有权

- `network_bridge`：可见浏览器、来源 User-Agent、原子 Cookie/localStorage 快照、`AndroidBrowserCookieSession`。
- `plugin_host_bridge`：Mihon/Venera ABI 适配；Mihon `AndroidCookieJar`、Venera HTTP 只消费共享会话，不拥有浏览器 UI。
- `plugin_host`：runtime descriptor 携带可选 `browserUserAgent`，Mihon synthetic revision 3。
- `apps/app`：刷新结果 Presentation、同 in-flight 合并、composition 原子详情刷新、持久真实目录回归拒绝、诊断 Trace；远程详情不得恢复直接 `source.loadComic` 的竞争路径。

## 设备复验

1. 清除旧 revision 2 synthetic 显示后打开同一 JMComic。
2. 从漫画源页或详情地球图标完成 Cloudflare，返回后等待自动重试。
3. 连续下拉刷新，验证真实章节不变、绿勾/红叉 2 秒消失。
4. 1、5、15 分钟后再次刷新。失败时导出 zic trace；重点查看 `source-verification-browser-result`、`browse-*`、`remote/local-refresh-*`、`chapter-catalog-regression-rejected`。
5. Trace 不应包含 Cookie 值或完整 opaque token。

## 未改变

Reader/Pipeline 7/3 下载窗口、2/1 预解码、current/transition 上传、5/3/2 lane、256 KiB chunk、GET/HEAD 零 body和 artifact/session 所有权均未改变。
