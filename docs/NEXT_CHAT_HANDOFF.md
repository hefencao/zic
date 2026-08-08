# dev.165 后续交接

唯一后续基线：`zic_v0.31.0-dev.165_artwork-lifetime-home-update-semantics.zip`。

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
10. `docs/adr/0144-mihon-catalogue-venera-lifecycle-media-network.md`
11. `docs/adr/0145-network-user-agent-and-transport-cache-ownership.md`
12. `docs/adr/0146-source-resource-atomic-binding-and-catalog-artwork-boundary.md`
13. `docs/adr/0147-home-projection-artwork-revision-runtime-generation-ownership.md`
14. `docs/adr/0148-artwork-source-lifetime-and-home-update-semantics.md`
14. `docs/audits/dev157-root-cause-owner-cleanup-audit.md`
15. `docs/audits/dev157-validation-results.md`
16. `docs/audits/dev158-compile-owner-blocking-audit.md`
17. `docs/audits/dev158-validation-results.md`
18. `docs/audits/dev163-venera-activation-history-cover-root-cause-audit.md`
19. `docs/audits/dev164-home-projection-artwork-runtime-generation-root-cause-audit.md`
20. `docs/audits/dev164-validation-results.md`
21. `docs/audits/dev165-artwork-lifetime-home-update-root-cause-audit.md`
22. `docs/audits/dev165-validation-results.md`

## 当前代码事实

- `HomeLibrarySession` 是已挂载 Home 的 write-through projection owner：chapter/SavedComic durable mutation成功后立即更新可见投影；详情/来源流程不得靠后续 `_reloadLibrary()` 追平。Reader page只 enqueue checkpoint，每个 route局部持有 final progress并在返回后只发布一次。
- session reload具有 projection revision：reload开始时捕获的旧 entries/SavedComic snapshot不得在 enrichment结束时覆盖更晚的 write-through chapter/saved/progress投影。
- `comicArtworkCacheSchemaRevision` 只有一个 owner。external browse/details/history均由 `ComicSourceResourceGateway`生成 `artwork-v2[:contentRevision]`；调用方不得再把基础 schema revision作为参数传入。local artwork直接使用同一 schema revision。
- 初次 external runtime activation 的 service-generation continuity属于 Android `PluginRuntimeServiceClient`：只有 pending `activateMihonRuntime/activateVeneraRuntime`可跨一个 died/disconnected Binder generation；Dart backend不再二次调用 activation。业务错误与 established-session invocation不进入该策略。
- Home外部封面仍把 source availability作为显式加载依赖；history/update Sliver仍持有 `section + canonical comic identity`稳定 key。dev.165不恢复 presentation retry/watchdog/evict。
- cache-owned durable artwork文件不再跨边界成为 `FileImage`。`ResourceCacheManager`从持久 byte store恢复后交付自持有 memory bytes；只有稳定本地导入文件可使用 `FileEncodedResourceSource`。
- Home updates不是“最近元数据/最近阅读”：仅已入书架且 `sourceUpdateAt`存在的漫画显示；章节目录已有基线后变化或发现新同源 version才产生 signal。远程无偏好记录默认不在书架。
- Reader SQLite仍由 storage-owned isolate按同章节 latest-wins合并，空闲约8秒提交、持续活跃最多约30秒提交；route不等待 durable barrier。
- 全局网络 User-Agent是 composition fallback，默认 Android Chrome 150并可设置；source显式 UA、Mihon browser-session UA优先。App presentation不得创建独立 HTTP client。
- shared source host replay只允许无状态媒体：禁止自动 redirect；redirect、`Set-Cookie`、非媒体 body或未知 client wrapper立即切 source-owned client。metadata/artwork必须走 `ResourceCacheManager`；`pageResponseLoaderFor/loadPageBytes`仅供 Reader/章节正文，由 DownloadSession/artifact接管。 full-byte 与 streaming 必须复用同一 response loader；章节下载只通过原子 `ChapterResourceAccess` 绑定，禁止恢复 byte/transport 双 setter。
- Mihon 1.6 ABI shim不能依赖 `kotlinx.coroutines`；独立 asset generator必须能用自身 classpath编译。
- Mihon 1.6/current章节入口是 `getMangaUpdate(manga, existingChapters, true, true)`；ZIC `CatalogueSource` shim与当前 Mihon一致，details/chapters均使用原始 `SManga`独立请求。combined能力缺失时才回退 legacy，且 `fetchChapterList`仍使用原始 manga。正文先 `getPageList(SChapter)`，能力缺失才 `fetchPageList`；禁止 synthetic和标题/URL/number猜测。
- `ComicSourceResourceGateway/ResourceCacheManager` 是 external artwork唯一恢复/cache owner。详情统一使用 `ComicDetailsArtworkLoader`，resource role显式穿过 loader；普通 artwork复用 `StableArtworkImage`，裁剪/尺寸测量最多一个显式 ImageStream listener，不得同时构建第二个 Image。Home、书架、漫画源、详情没有 timer retry、first-frame watchdog、resume retry、ImageCache eviction或 App级短时 Future join。 `CachedBrowsableComicSource` 只缓存 catalog metadata，不再提供 artwork load facade。
- Mihon raw comicId只用于 runtime locator；durable artwork与封面 presentation key使用 canonical comic identity。`mihon:resource:` 等插件 URI只走 gateway。
- Mihon page/cover request plan保留 `imageRequest(page)` 的 URL/method/headers/body；GET/HEAD无 body。共享 transport无 Venera默认 UA。host直连若 2xx前缀不是编码图片，在进入 Pipeline前使用现有 source-owned runtime network兼容路径；正常图片仍走统一流式 transport。
- Cloudflare可见浏览器沿用 dev.154/dev.155：真实 WebView UA与 Cookie/localStorage同 revision handoff；typed classifier与浏览器完成 probe分离；验证后按稳定 sourceId解析 replacement adapter。
- 外部插件 manifest按记录容错。只有 payload安装/升级走事务式 replacement；settings与Venera Web登录原地更新，不 restart。Mihon浏览器 handoff保留受限 Mihon-only restart。生产 runtime session安全上限32，不能恢复通用8-session用户上限。
- Reader/Pipeline网络、decode、texture参数未因本轮问题改变：encoded前7/后3，holder 7/5/3/2，decode前2/后1，normal network5/decode3/upload2。
- Native identity保持 `zic-media-core-dev134-abi6-lib00121400`。
- 当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`；不得从旧版本偷偷补入。

## 下一步真机优先验证

- 长会话记录 progress SQLite事务次数和 Reader pop帧时序；不得每页写盘，也不得在退出后整库 reload。
- 分别用明确 chapterList扩展与 combined-only TachiyomiX 1.6扩展验证目录调用次数/结果；出现空或单项时先看实际 API返回，不恢复 synthetic fallback。
- 同一 Mihon漫画连续 browse → details → history，多次详情补全/封面 URL变化后，canonical artwork identity必须一致；成功封面普通 rebuild/resume不得重新请求。
- 重现 response cache trim/Reader往返，确认已经 FirstFrame的封面不因 cache文件回收而 DecodeFailed；确认 Home updates仅由 shelf + sourceUpdateAt驱动。

## 不可改变的稳定边界

- 不缩小 Reader 7/3、holder 7/5/3/2、decode 2/1来掩盖性能问题。
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture。
- 不在 App/Reader新增 transport、正文缓存、frame/session owner。
- 不恢复 synthetic Mihon chapter、标题/URL启发式目录去重，也不反转回 explicit chapterList-first；不得并行/重复调用两套章节API。
- 不恢复 presentation封面 retry/watchdog/evict/Future join。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch命令：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
