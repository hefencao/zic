# dev.142 后续交接

唯一后续基线：`zic_v0.31.0-dev.142_preview-width-cover-recovery-search-filters-refresh.zip`。

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
15. `docs/audits/dev142-preview-cover-search-refresh-audit.md`
16. `docs/audits/dev142-validation-results.md`

## 当前代码事实

- NetLane 是唯一网络调度权威；不存在 holder/playback 驱动的网络资格门控。
- encoded window 为前 7/后 3，深度 decode 角色为前 2/后 1，holder 最大水位为 7/5/3/2。
- transition depth=0 独立执行一帧 bootstrap；获得首帧后恢复 staged current/neighbor refill。
- holder-driven playback 缺帧时保留当前 output；没有 startup-buffer。
- Reader 退出后最多保留 1 个 idle chapter resource session、TTL 2 分钟；used texture 不保留。
- response cache 与 page artifact cache 是两个权威平面；App/Reader 没有私有正文 LRU。
- 首页、漫画源卡片和详情封面分别对 encoded-source Future 做有界重试；`RecoverableArtworkImage` 只驱逐失败 provider 并重建 ImageStream，App resume 会恢复仍失败项。不得通过清空全局 image/response cache 修复单张图。
- 漫画源页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态仅用 chip 色彩/图标表示。
- 浮动搜索展开态优先消费返回和垂直拖动/滚动手势；搜索历史持久化。Mihon `getFilterList()` 的 CheckBox/TriState/Select/Group 通过 opaque ID 投影为搜索框上方过滤标签，UI 不持有插件 Filter 对象。
- 浏览页使用 catalog cache-first/background-refresh；稳定字段无变化时不更新。边缘下拉达到阈值后调用强制刷新，保留现有内容直到新结果到达。
- 详情预览按原顺序装箱，行缩放跨度受 `sqrt(1.2)` 限制；完整行在面积比不超过 1.2 的前提下尽量利用屏幕宽度。阅读设置每行最大数量默认 4、范围 1–8，预览区域封顶屏幕高度 80%。
- Android 使用默认 platform channel、单 blit lane 和 fresh used texture lifecycle。
- Native identity 保持 `zic-media-core-dev134-abi6-lib00121400`。
- 当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`；不得从旧版本偷偷补入，除非用户提供或明确指定来源。

## 下一步

- 优先执行 `IMPLEMENTATION_PLAN.md` 的真机与完整 Flutter/Android 工具链闭环。
- 封面问题复验需分别制造 source Future 失败与 Flutter decode 失败，确认自动重试、resume 恢复和局部 provider 驱逐。
- Mihon 过滤需用真实扩展检查默认 FilterList、Group 嵌套、TriState 与 Select 回传。
- 预览排版需在不同屏宽和宽高比集合上检查左右边缘利用、面积比、每行上限与 80% 高度约束。

## 不可改变的稳定边界

- 不缩小 7/3、7/5/3/2 或 5/3/2 来掩盖问题；
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture 或 CPU affinity；
- 不在 Reader/App 新增 transport、正文缓存、cursor、frame 或 session 所有权；
- 不把 Mihon Filter 对象、网络连接或缓存正文传入 UI；
- 正式 ZIP 不含 `.zic-workspace.json`，Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
