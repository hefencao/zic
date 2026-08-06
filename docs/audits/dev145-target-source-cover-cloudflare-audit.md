# dev.145 目标来源、封面与 Cloudflare 审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.144_cover-first-frame-detail-source-layout.zip`。
- `zic-debug-trace-2026-08-06T15-16-37.jsonl`。
- `错误报告(20260806-151859).txt`。

## 证据

- 禁漫天堂 browse 多次 `cacheHit=false` 并返回 `sourceVerificationRequired`；切回 Venera 立即 `cacheHit=true`。旧 UI 只以 `_items.isNotEmpty` 判断保留内容，没有验证 projection source owner。
- 同一 Venera cover identity 在同一时间出现重复请求、相同 memory byteLength 和重复首帧；Home 更新与历史可同时创建同一漫画 owner。
- Home card key 使用 resume chapter identity，章节/进度变化会销毁 cover State。
- dev.144 首帧 watchdog 在 source ready 后计时，离屏/未 paint 也可能被当作 encoded cache 失效。
- 错误报告中的 Preview/Comment 调用未在局部变量上保持 capability 类型。

## 修复

- 引入目标 source 最近缓存请求投影和 `_projectionSourceId`，切换时原子替换。
- force refresh 的验证错误自动打开一次 WebView并重试一次。
- 删除来源 chip 图标。
- cover card 使用稳定 key；重复请求合并，失败 join 立即释放；watchdog只重建 provider。
- 显式 `ComicPreviewSource`/`ComicCommentSource` 局部收窄。

## 被否决方案

- 不以目标请求失败为理由保留旧 source 卡片。
- 不清空全部 catalog/image cache。
- 不增加封面重试频率或继续让 watchdog强制刷新 bytes。
- 不吞掉 Cloudflare 验证错误或无限循环 WebView。
