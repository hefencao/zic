# dev.143 后续交接

唯一后续基线：`zic_v0.31.0-dev.143_cover-stability-preview-cookie-runtime-refresh.zip`。

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
16. `docs/audits/dev143-cover-plugin-preview-refresh-audit.md`
17. `docs/audits/dev143-validation-results.md`

## 当前代码事实

- NetLane 是唯一网络调度权威；不存在 holder/playback 驱动的网络资格门控。
- encoded window 为前 7/后 3，深度 decode 角色为前 2/后 1，holder 最大水位为 7/5/3/2。
- transition depth=0 独立执行一帧 bootstrap；获得首帧后恢复 staged current/neighbor refill。
- holder-driven playback 缺帧时保留当前 output；没有 startup-buffer。
- Reader 退出后最多保留 1 个 idle chapter resource session、TTL 2 分钟；used texture 不保留。
- response cache 与 page artifact cache 是两个权威平面；App/Reader 没有私有正文 LRU。
- 首页、漫画源卡片和详情封面仅做单次后台 source retry；loader closure identity 不得触发重试。`RecoverableArtworkImage` 重建期间保持稳定占位图，成功帧到达才切换；App resume 可恢复仍失败项。
- 漫画源页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态仅用 chip 色彩/图标表示。
- 浮动搜索展开态优先消费返回和垂直拖动/滚动手势；搜索历史持久化。Mihon `getFilterList()` 的 CheckBox/TriState/Select/Group 通过 opaque ID 投影为搜索框上方过滤标签，UI 不持有插件 Filter 对象。
- 浏览页使用 catalog cache-first/background-refresh；稳定字段无变化时不更新。边缘下拉达到阈值后调用强制刷新，保留现有内容直到新结果到达。
- 详情预览按原顺序装箱：实际行内含横图则最多 2 张、纯竖图则最多 3 张；只在相邻三个候选内做最小局部重排；设置项仍是更严格上限。行宽直接用于反算等面积 tile，内部无 Card/水平 padding，异常末行仍保持面积比不超过 1.2。
- Android 使用默认 platform channel、单 blit lane 和 fresh used texture lifecycle。可见浏览器 Cookie snapshot 按 revision 每 runtime/站点/UA 只导入一次；retryable runtime lifecycle envelope 会重新激活并重试一次。远程详情页通过稳定 source ID 获取当前 active adapter，不保留插件重启前的关闭 session。
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
