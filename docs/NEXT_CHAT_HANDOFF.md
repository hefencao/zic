# dev.157 后续交接

唯一后续基线：`zic_v0.31.0-dev.157_progress-chapter-artwork-owner-cleanup.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0122-current-reader-pipeline-authority-consolidation.md`
8. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
9. `docs/adr/0140-cloudflare-browser-session-history-and-plugin-persistence.md`
10. `docs/adr/0142-reader-checkpoint-mihon-catalog-artwork-presentation-ownership.md`
11. `docs/audits/dev157-root-cause-owner-cleanup-audit.md`
12. `docs/audits/dev157-validation-results.md`

## 当前代码事实

- Reader页面变化只 enqueue latest progress；SQLite在 storage-owned isolate内按同章节 latest-wins合并，空闲约8秒提交、持续活跃最多约30秒提交。Reader route不等待 durable barrier。返回后 Home只发布最终 progress一次，详情只替换当前章节，不全量 reload library。
- Mihon章节目录优先 `getChapterList/fetchChapterList`；成功（含空）即权威，真实调用错误直接失败。只有该能力不存在时，才调用一次 TachiyomiX 1.6 combined update并传入已知章节原顺序。禁止 synthetic chapter、按标题猜“开始阅读”；仅完全相同非空 `SChapter.url`按 source locator折叠。
- `ComicSourceResourceGateway/ResourceCacheManager` 是 external artwork唯一恢复/cache owner。Home、书架、漫画源、详情没有 timer retry、first-frame watchdog、resume retry、ImageCache eviction或 App级短时 Future join。失败 presentation稳定占位，显式刷新/资源 revision/稳定 identity变化才重新加载。
- Mihon raw comicId只用于 runtime locator；durable artwork与封面 presentation key使用 canonical comic identity。`mihon:resource:` 等插件 URI只走 gateway。
- Cloudflare可见浏览器沿用 dev.154/dev.155：真实 WebView UA与 Cookie/localStorage同 revision handoff；typed classifier与浏览器完成 probe分离；验证后按稳定 sourceId解析 replacement adapter。
- 外部插件 manifest按记录容错，可从 `.bak/.part/.invalid`恢复 owned payload；激活仍执行 hash/签名/ABI/entry检查。
- Reader/Pipeline网络、decode、texture参数未因本轮问题改变：encoded前7/后3，holder 7/5/3/2，decode前2/后1，normal network5/decode3/upload2。
- Native identity保持 `zic-media-core-dev134-abi6-lib00121400`。
- 当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`；不得从旧版本偷偷补入。

## 下一步真机优先验证

- 长会话记录 progress SQLite事务次数和 Reader pop帧时序；不得每页写盘，也不得在退出后整库 reload。
- 分别用明确 chapterList扩展与 combined-only TachiyomiX 1.6扩展验证目录调用次数/结果；出现空或单项时先看实际 API返回，不恢复 synthetic fallback。
- 同一 Mihon漫画连续 browse → details → history，多次详情补全/封面 URL变化后，canonical artwork identity必须一致；成功封面普通 rebuild/resume不得重新请求。

## 不可改变的稳定边界

- 不缩小 Reader 7/3、holder 7/5/3/2、decode 2/1来掩盖性能问题。
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture。
- 不在 App/Reader新增 transport、正文缓存、frame/session owner。
- 不恢复 synthetic Mihon chapter、标题启发式目录去重或两套 chapter API并行/串行重复请求。
- 不恢复 presentation封面 retry/watchdog/evict/Future join。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch命令：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
