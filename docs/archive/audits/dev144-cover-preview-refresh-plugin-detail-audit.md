# dev.144 封面、预览、刷新与插件详情审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.143_cover-stability-preview-cookie-runtime-refresh.zip`
- 设备截图：详情布局、预览右侧空白和章节投影问题。
- Trace：`zic-debug-trace-2026-08-06T13-39-55.jsonl`。

## 证据

- 本地 cover identity 首次从 durable cache 返回 5,906,374 字节并出帧；后续再次返回相同完整字节后，直到 Trace 结束没有 `homeCoverFirstFrame`，也没有 decoder failure。
- 三次 Mihon 详情刷新在 external plugin host ready 前几十毫秒失败，说明详情不能把 host activation 当作同步前置条件。
- 已保存 catalog 可用于立即绘制详情，实时来源刷新属于后台 revalidation。

## 修复

- 增加 2.5 秒无首帧 watchdog，并规范 recovery 使用稳定 `role=cover` identity。
- 详情以持久 catalog 首屏，等待 current adapter；预览/评论在调用时重新解析。
- 完整预览行铺满图片媒体宽度；只对稀疏末行应用 2.4 倍上限；展开高度 90%。
- 刷新进度和结果位置统一归属 `AppPullToRefresh`。
- 真实章节存在时剔除 compatibility fallback，包括持久 entry 最终投影。
- 简介 Card、评论换行清理和继续区间距作为同一详情布局收口。
