# dev.152 后续交接

唯一后续基线：`zic_v0.31.0-dev.152_mihon-cloudflare-cookie-handoff.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0117-reader-resource-session-retention-and-affinity-removal.md`
8. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
9. `docs/adr/0121-vibevenera-independent-transition-first-frame.md`
10. `docs/adr/0122-current-reader-pipeline-authority-consolidation.md`
11. `docs/adr/0123-home-cold-start-primary-and-optional-runtime-deferral.md`
12. `docs/adr/0124-home-cover-independent-foreground-completion.md`
13. `docs/adr/0126-source-owned-browse-sections-floating-search-and-swr.md`
14. `docs/adr/0127-preview-width-cover-recovery-search-filters-and-refresh.md`
15. `docs/adr/0128-cover-stability-preview-rows-cookie-runtime-refresh.md`
16. `docs/adr/0129-cover-first-frame-detail-source-and-layout.md`
17. `docs/adr/0130-target-source-cache-cover-identity-and-cloudflare-fallback.md`
18. `docs/adr/0131-identity-version-notice-synthetic-and-cloudflare-handoff.md`
19. `docs/adr/0132-reader-progress-version-view-start-action-verification.md`
20. `docs/adr/0136-source-verification-runtime-replacement.md`
21. `docs/adr/0137-mihon-cloudflare-cookie-handoff-and-loop-guard.md`
22. `docs/audits/dev152-mihon-cloudflare-handoff-audit.md`
23. `docs/audits/dev152-validation-results.md`

## 当前代码事实

- Mihon 设备扫描只覆盖系统共享 APK；页面自动加载默认仓库，并以仓库 package name进行精确探测。Mihon 私有目录扩展必须从 ZIC仓库安装。
- 扫描结果必须保留枚举数、候选数、精确命中和逐 APK失败阶段；不得恢复 `runCatching(...).getOrNull()` 静默丢弃。

- NetLane 是唯一网络调度权威；不存在 holder/playback 驱动的网络资格门控。
- encoded window 为前 7/后 3，深度 decode 角色为前 2/后 1，holder 最大水位为 7/5/3/2。
- transition depth=0 独立执行一帧 bootstrap；获得首帧后恢复 staged current/neighbor refill。
- holder-driven playback 缺帧时保留当前 output；没有 startup-buffer。
- Reader 退出后最多保留 1 个 idle chapter resource session、TTL 2 分钟；used texture 不保留。
- response cache 与 page artifact cache 是两个权威平面；App/Reader 没有私有正文 LRU。
- 首页封面卡片使用 section + comic identity 的稳定 State key；同 identity 的并发 owner 共享 source Future/provider，失败 Future 立即退出 join。无首帧 watchdog 只重建同一 provider stream，不刷新 encoded bytes；明确 decoder exhaustion 才可 force-refresh。
- 漫画源页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态只用 chip 背景色表示。source 切换立即投影目标精确/最近缓存；目标错误不允许旧 source 内容滞留。`sourceVerificationRequired` 会携带实际失败 URL/status/clearance存在性：仅缺少 clearance时自动打开一次验证 WebView，验证必须得到新 clearance；已有 clearance仍被 challenge时不自动循环。WebView返回后按稳定 source ID取得重启后的当前 adapter，重载 section/filter并强制刷新一次，绝不继续调用关闭的旧 session。
- 浮动搜索展开态优先消费返回和垂直拖动/滚动手势；搜索历史持久化。Mihon `getFilterList()` 的 CheckBox/TriState/Select/Group 通过 opaque ID 投影为搜索框上方过滤标签，UI 不持有插件 Filter 对象。
- 浏览页使用 catalog cache-first/background-refresh；稳定字段无变化时不更新。边缘下拉达到阈值后调用强制刷新，保留现有内容直到新结果到达。
- 详情预览按原顺序装箱：实际行内含横图则最多 2 张、纯竖图则最多 3 张；只在相邻三个候选内做最小局部重排；设置项仍是更严格上限。行宽直接用于反算等面积 tile，内部无 Card/水平 padding，完整行铺满媒体宽度，只有稀疏末行允许放大到参考完整行面积的 2.4 倍。
- Android 使用默认 platform channel、单 blit lane 和 fresh used texture lifecycle。Mihon 的可见浏览器 Cookie snapshot由新 runtime `AndroidCookieJar` 同步导入进程内 cookie map，首请求不等待异步 CookieManager；retryable runtime lifecycle envelope仍只重新激活并重试一次。远程详情页通过稳定 source ID 获取当前 active adapter，不保留插件重启前的关闭 session。
- 同源版本关系按 source/predecessor/successor 复合身份双向查询；详情正文提供查看新/旧版本和迁移双动作，多个版本先选择。查看路由使用临时 key，但多个版本阅读历史严格按 raw identity 分离；迁移仍走旧比较确认。Reader 仅首次提醒。
- App 不清理 synthetic“开始阅读/正文”。Mihon adapter 只去除与真实章节并存的独立开始阅读动作；单独 gallery“正文”保留。
- Reader progress 单 writer 合并，正常退出前等待最终写入，详情 route 返回后立即刷新历史；生命周期 checkpoint 只提供 best effort。
- `sourceVerificationRequired` 只由统一 typed 403/503 challenge detector 产生；兼容 interceptor 不创建隐藏 WebView。
- `CachedBrowsableComicSource.resolveComicWebUri` 保持 `Uri?`；调用方负责 website fallback。
- Mihon common runtime只预检稳定 `AndroidCookieJar`，不直接依赖内部 `AndroidBrowserCookieSession`。APK metadata可从字符串资源解析，并支持逗号/分号/换行多入口。后台设备扫描错误保存在 controller并由插件页显示，不能再把扫描异常伪装成空列表。
- Mihon common runtime中的 `SourceVerificationRequiredException` 是动态 ABI；network bridge consumer R8规则必须保留其原始类名和成员。不得通过删除完整性预检绕过 Release缺类。
- Native identity 保持 `zic-media-core-dev134-abi6-lib00121400`。
- 当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`；不得从旧版本偷偷补入，除非用户提供或明确指定来源。

## 下一步

- 优先执行 `IMPLEMENTATION_PLAN.md` 的真机与完整 Flutter/Android 工具链闭环。
- 封面问题复验需分别制造 source Future 失败与 Flutter decode 失败，确认自动重试、resume 恢复和局部 provider 驱逐。
- Mihon 过滤需用真实扩展检查默认 FilterList、Group 嵌套、TriState 与 Select 回传。
- 预览排版需在不同屏宽和宽高比集合上检查完整行边缘利用、稀疏末行 2.4 倍上限、每行上限与 90% 高度约束。

## 不可改变的稳定边界

- 不缩小 7/3、7/5/3/2 或 5/3/2 来掩盖问题；
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture 或 CPU affinity；
- 不在 Reader/App 新增 transport、正文缓存、cursor、frame 或 session 所有权；
- 不把 Mihon Filter 对象、网络连接或缓存正文传入 UI；
- 正式 ZIP 不含 `.zic-workspace.json`，Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```

- encoded source ready 后若 2.5 秒仍没有首帧或错误，封面只允许局部 revalidate 同一 cover identity 一次；不得恢复 loader-closure 重试或清空全局 cache。
- 远程详情必须先显示缓存 catalog，并通过 `resolveSource(sourceId)` 等待/取得当前 adapter；预览和评论闭包不得捕获旧 runtime source。
- 不得在 App 层按 synthetic identity 或标题清理章节；独立开始阅读动作的去重只属于 Mihon adapter。
- 详情和漫画源刷新进度、勾/叉必须继续由 `AppPullToRefresh` 一套组件拥有。
