# ADR 0139：Cloudflare 可见浏览器稳定完成边界

**状态：Accepted**

## 背景

dev.153 将 `sourceVerificationRequired` 的触发边界收紧到真实交互 challenge，并允许可见 WebView 在目标页已无 challenge DOM 时自动完成 handoff。真机继续暴露另一类错误：Cloudflare 验证尚未完成，`onPageFinished` 已触发；由于完成探针只检查 `challenge-error-title/text`，Turnstile iframe、`challenge-form`、`cf-chl-*` 容器或 `Just a moment…` 中间页没有被识别，WebView 会过早返回 App。

`onPageFinished` 只能证明一次主文档 load回调结束，不能证明 Cloudflare 的 JS challenge、iframe或后续导航已经稳定结束。

## 决策

1. `sourceVerificationRequired` 的网络分类继续保持 dev.153 的严格边界，避免普通 403误触发 WebView；浏览器内部“验证是否仍在进行”使用更保守的宽探针，两者不得共用同一判据。
2. 验证浏览器在 `onPageStarted` 时推进 navigation generation并清空稳定窗口。旧 generation 的延迟 probe不得完成新页面。
3. `onPageFinished` 后不立即返回。先等待初始 settle，再每 500 ms轮询；必须同时满足：同站点 URL稳定、`document.readyState == complete`、WebView progress为 100、没有可见 challenge UI。
4. challenge UI包括错误标题、running/form容器、Turnstile、`cf-chl-*`、Cloudflare challenge iframe，以及 `Just a moment`、`Verify you are human`、`Performing security verification`、`Checking your browser`等可见中间态。
5. 页面必须连续稳定 3 秒没有上述 challenge证据，才写入最终 Cookie/UA snapshot并自动返回。任意新导航、loading或 challenge重新出现都会重置该窗口。
6. 用户手动返回时仍使用现有完成检查；challenge未稳定完成时不得伪装为成功 handoff。

## 后果

- Cloudflare challenge加载过程中即使先触发 `onPageFinished`，也不会提前退出 WebView。
- Turnstile或 JS challenge在同一个文档内动态变化时，无需等待第二次 `onPageFinished`，持续 probe也能在真正完成后自动返回。
- 已经正常可访问、从未出现 challenge的页面会多等待约 4.5 秒（初始 settle +连续稳定窗口），换取不误判验证完成。
- 本 ADR只改变可见浏览器完成条件，不扩大网络层 `sourceVerificationRequired` 判定范围。

## 取代关系

本 ADR取代 ADR 0138 中“单次 `onPageFinished` 后确认无 `challenge-error-title/text` 即可完成”的浏览器完成边界；ADR 0138 的严格网络分类、Cookie snapshot保留与自动回退 loop guard继续有效。
