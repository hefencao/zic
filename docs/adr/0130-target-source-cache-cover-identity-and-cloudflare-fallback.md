# ADR 0130：目标来源缓存投影、封面身份与 Cloudflare 回退

**状态：Accepted**

## 背景

dev.144 设备 Trace 显示，切换到请求失败的 Mihon 来源时页面继续展示 Venera 旧缓存；强制刷新返回 `sourceVerificationRequired` 但没有进入 WebView。另一个 Trace 片段中，同一 cover identity 在同一时间存在两个请求、两个相同 memory source 与两个首帧，说明问题不是单一 ImageStream，而是重复 Presentation owner 与不稳定 State 生命周期。dev.144 watchdog 还会把“2.5 秒没有 frame callback”直接解释成 encoded bytes 失效。

## 决策

1. Catalog 暴露目标 source 最近一次 `CachedSourceBrowseSnapshot`，包含 page 与 section/query/offset/filter request identity。
2. source 切换先改变 projection owner；依次使用目标精确缓存、目标最近缓存、目标 loading。目标失败不得保留旧 source 内容。
3. 显式强制刷新得到 `sourceVerificationRequired` 时自动打开一次目标 source WebView，关闭后强制重试一次；重试禁止再次自动打开。
4. 来源 chip 只用背景色区分生态，删除 JS/插件图标。
5. Home cover card State key 使用 section + comic identity；旧 chapter key 只作为交互定位 key。相同 cover identity 的并发 source 请求合并，失败 Future 立即移出 join。
6. 首帧 watchdog 只重建同一 provider stream 一次。实际 decoder error局部恢复耗尽后，才允许使用稳定 `role=cover` identity 强制读取 encoded source。
7. Preview/Comment capability 在调用点显式收窄局部变量，避免 Dart 对 getter/async 边界的类型提升失效。

## 所有权

- 浏览请求缓存与最近投影：`catalog/CachedBrowsableComicSource`。
- 当前 projection owner与验证动作：App source browser Presentation。
- encoded cover bytes：统一 response cache/source gateway。
- Home cover State/provider join：Home composition/presentation，不保存第二份 bytes。
- Cloudflare Cookie/WebView：network bridge 与插件 runtime。

## 取代关系

本 ADR 取代 ADR 0129 中“无首帧直接强制重读 encoded source”的部分；ADR 0129 的详情 current-source、布局、刷新和章节投影决策继续有效。
