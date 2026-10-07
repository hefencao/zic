# ADR 0132：Reader 进度、版本查看、开始阅读动作与验证分类

**状态：Accepted**

## 背景

dev.146 将来源合法的独立“开始阅读”动作与 App synthetic fallback 混为一类，在 manifest、SavedComic 和 UI 多层清理；同时详情版本入口只保留单一 successor 提示，无法查看多个新旧版本。Reader progress 由多个异步写入并行提交，正常退出不等待最终写入，详情页继续显示旧 snapshot。Cloudflare 主网络和兼容 interceptor 还存在 typed/untyped 两套判定。

## 决策

1. App 删除所有 synthetic 章节扫描和持久清理。Mihon adapter 在目录进入 Catalog 前，仅去除与其他真实章节并存、标题精确归一为独立开始阅读动作的条目；单独“正文”gallery fallback 保留。
2. Reader progress 使用一个 active writer 与一个 latest pending value。正常 route pop 强制 checkpoint并等待队列清空；详情页在 Reader 返回后立即重载。稳定翻页和 inactive/paused/detached best-effort checkpoint，进程强杀不承诺完成。
3. 同源版本详情采用 VibeVenera 的查看/迁移分离结构。successor 和 predecessor 都可查看；multiple versions 先选择。查看使用 temporary route identity 去重，但持久历史、SavedComic、章节、下载和 artifact继续按 target raw identity。
4. 迁移不复用查看路径的临时 key，继续进入 ZIC 原严格比较确认 UI；exact chapter identity 才复制状态，sequence-only 不复制。
5. `sourceVerificationRequired` 只由 typed host detector 产生。403/503 必须有 `cf-mitigated: challenge` 或明确 challenge body marker。主网络和 Mihon ABI 兼容 interceptor 委托同一 detector；删除隐藏 WebView、等待和消息文本猜测。
6. dev.147 曾让 `MihonRuntimeDriver` 直接 import `AndroidBrowserCookieSession`；该实现依赖已由 ADR 0133 收回 `AndroidCookieJar` 稳定边界，避免内部类成为 plugin common runtime ABI。

## 后果

来源动作与 App fallback 不再相互污染；多个版本可以安全查看且历史分离；正常退出 Reader 后详情立即更新；Cloudflare 验证错误分类在所有 Mihon网络入口一致。