# dev.154 Cloudflare 浏览器稳定完成审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.153_mihon-cloudflare-browser-completion-loop-guard.zip`。
- 真机现象：Cloudflare 尚未验证完毕，可见 WebView已自动关闭并返回 App。

## 根因

- dev.153 直接在 `onPageFinished` 中执行 challenge probe并完成 handoff。
- probe只覆盖 `challenge-error-title` 和 `challenge-error-text`，没有覆盖 Turnstile、challenge form、running容器、`cf-chl-*`或 `Just a moment…` 中间态。
- Cloudflare challenge可以在主页面 load结束后继续通过 JS/iframe运行，因此 `onPageFinished` 不是验证完成信号。

## 修复

- 增加 navigation generation，任何新导航都会使旧 probe失效。
- 页面完成后先 settle，再以 500 ms周期持续 probe。
- browser completion probe覆盖可见 Turnstile、challenge form、running容器、`cf-chl-*`、challenge iframe和典型验证文本。
- 只有同站点、ready/progress完成且连续 3 秒无 challenge证据，才自动 capture并返回。
- network classifier不随 browser completion probe放宽。

## 被否决方案

- 不恢复“必须出现新的 `cf_clearance` 才算成功”。
- 不仅靠固定延迟后直接返回。
- 不把 `challenge-platform`脚本存在本身重新作为网络层验证触发条件。
- 不要求用户每次手动返回以完成 handoff。
