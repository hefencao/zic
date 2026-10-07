# ADR 0138：Cloudflare 浏览器完成边界与自动回退保护

**状态：Accepted**

## 背景

dev.152 将浏览器 snapshot同步导入 Mihon runtime，但仍把“删除旧 `cf_clearance` 后必须得到新 token”作为 WebView完成条件。设备上实际出现：runtime 403被分类为 `sourceVerificationRequired`，WebView打开同一 URL却没有挑战页面；浏览器有时被取消、有时停留，返回后的 runtime仍报告 `cf_clearance=absent`。同时 `NetworkBrowserSnapshotStore.begin()` 会在 WebView刚打开时覆盖旧 snapshot，使一次失败/取消的验证尝试本身可以破坏此前可用会话。

## 决策

1. Cloudflare HTML分类对齐 Mihon当前交互挑战边界：`cf-mitigated: challenge` 可直接确认；否则必须为 403/503 + Cloudflare Server + `challenge-error-title`/`challenge-error-text`。仅 challenge脚本、`Just a moment`或普通 Cloudflare 403不进入验证恢复。
2. 可见浏览器不在进入验证模式前删除 `cf_clearance`。同站点页面没有真实 challenge DOM时，页面本身已经可访问，保存当前 Cookie/UA snapshot并完成 handoff；不要求一定产生新 clearance。
3. `NetworkBrowserSnapshotStore.begin()` 对同站点、同 UA且仍在 TTL 内的 snapshot保留 Cookie/localStorage及原 revision；成功 `update()` 才推进 revision。空 Cookie capture不得覆盖已有非空 handoff。
4. Presentation按 `sourceId + request URL`记录验证浏览器尝试。手动和自动 handoff都消耗自动 fallback额度；恢复后仍失败时普通刷新不再自动打开，用户仍可以显式再次验证。成功 browse清除该 source的 guard。
5. 浏览器 handoff完成后继续沿用 source ID resolver取得 replacement runtime adapter，再重载 section/filter与 browse。

## 后果

- geo/access block或普通 Cloudflare 403不会再误导用户反复进入空白/正常 WebView。
- 打开或取消一次浏览器不会先擦除仍有效的跨进程 Cookie snapshot。
- WebView可以完成“复制已有有效浏览器会话”而不仅是“生成新 cf_clearance”。
- 如果浏览器网络栈可访问而 OkHttp仍被站点拒绝，一次恢复后会保留真实错误与手动入口，不形成自动弹窗循环。

## 取代关系

本 ADR取代 ADR 0137 中“验证前删除旧 clearance且必须获得新 clearance才算成功”的完成边界；ADR 0137 的 typed failure details、同步 CookieJar导入和 replacement source生命周期继续有效。
