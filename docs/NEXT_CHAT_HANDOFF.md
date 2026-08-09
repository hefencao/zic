# dev.186 后续交接

唯一后续基线：`zic_v0.31.0-dev.186_venera-previous-request-plan-pressure-source-open-stages.zip`。

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
15. `docs/adr/0149-retained-artwork-persistence-and-invalidation-boundary.md`
16. `docs/adr/0150-source-browse-cover-and-filter-presentation-boundary.md`
17. `docs/adr/0152-mihon-source-filter-schema-state-ownership.md`
18. `docs/adr/0153-mihon-cleartext-media-and-download-retry-ownership.md`
19. `docs/adr/0154-source-filter-view-shelf-projection-download-feedback.md`
20. `docs/adr/0155-external-browse-runtime-protocol-field-ownership.md`
21. `docs/adr/0156-source-migration-version-view-and-update-badge-ownership.md`
22. `docs/adr/0161-vibevenera-rhttp-startup-transport.md`、`docs/adr/0162-modern-toolchain-rhttp-stream-framing.md`、`docs/adr/0163-openjdk25-relative-window-output-retention.md`、`docs/adr/0164-artifact-readthrough-preserves-task-control.md`、`docs/adr/0165-rhttp-raw-stream-downloadjob-single-framing.md`、`docs/adr/0166-current-bootstrap-execution-and-venera-physical-preemption.md`、`docs/adr/0167-receiving-state-detach-current-previous-handoff.md`、`docs/audits/dev184-current-previous-receiving-state-root-cause-audit.md`、`docs/audits/dev184-validation-results.md`、`docs/adr/0168-adjacent-previous-normal-pressure-preemption.md`、`docs/audits/dev185-adjacent-previous-pressure-root-cause-audit.md`、`docs/audits/dev185-validation-results.md`、`docs/adr/0169-venera-previous-request-plan-pressure-and-source-open-stages.md`、`docs/audits/dev186-venera-request-plan-pressure-root-cause-audit.md`、`docs/audits/dev186-validation-results.md`
23. `docs/adr/0158-venera-transport-preemption-and-native-source-lock-ownership.md`、`docs/audits/dev175-venera-transport-native-ingress-root-cause-audit.md`、`docs/audits/dev175-validation-results.md`

## 当前代码事实

- Mihon/source媒体 URL继续由插件 request plan拥有；Android宿主以统一 Network Security Configuration允许 source实际返回的 HTTP(S)媒体，不维护 WNACG/wnimg域名白名单、不擅自 HTTPS改写。
- external runtime `retryable=true`投影为 domain `ErrorCode.network`；确定性 `UnknownServiceException`不标记 transient。Reader下载 retry唯一属于 `LiveCoordinator`，non-retryable/source失败与网络恢复耗尽在当前 demand内 terminal，source listener/finally不能重新提交。
- 漫画源 browse 内容 revision不再承担 artwork revision：分页、SWR后台刷新、详情回写导致的 browse projection变化都不能全局重建封面 Future/ImageProvider；仅 cover URI自身变化或显式来源 artwork refresh触发重新加载。source card Sliver owner key使用 canonical comic identity，raw plugin locator只用于调用/交互。
- source filter唯一 schema事实是来源实际 `getFilterList()`：非空才显示“筛选”，空列表不发明入口。`filterState`只保存用户 override；独立 filter-view/useFilters mode决定是否执行筛选。direct apply空 override执行插件默认 FilterList且“筛选”获得焦点；filtered request不继承 Latest/Popular section。external browse typed factory/validator/adapter必须共享字段契约：schema v1新增 `useFilters` 可缺省为 false，未知字段仍严格拒绝。首次普通 section仍由当前 Presentation排序第一项决定。
- Mihon Filter bridge按官方 Header/Separator/Select/Text/CheckBox/TriState/Group/Sort基类识别插件自定义子类，保留 Group树；runtime请求使用类型化 `filterState` override，不能退回 concrete class-name猜测或 flat `filterIds`。
- source card只投影 Home事实：已入书架左上显示书架图标并变暗；`sourceUpdateAt`存在时右上显示独立更新感叹号。详情恢复通用“迁移漫画源”：同源只用来源确认 relation并可直接查看，跨源可搜索候选；所有迁移统一走严格比较确认。Home/书架下载完成勾仍是显式命令瞬时反馈。
- durable artwork persistence在 `ResourceCacheManager/FileResourceCacheByteStore` 内分为 `transient/retained`：browse/preview为 transient；library/history/details cover在同一 canonical key上晋升 retained。retained不受自动 LRU/TTL/manual transient trim影响，只接受精确 artwork失效、整漫画资源删除或用户清缓存。
- catalog metadata refresh使用 `invalidateComicMetadata`，不得按 comic namespace连坐 artwork；真正删除漫画时才调用 `invalidateAllComicResources`。
- maintenance统计/trim接口是 storage/cache内部纯契约；`ResourceCacheByteStoreUsage/TrimReport/Maintenance`存在，但任何 `locate()/PersistedResourceFile/FileAccess`借用路径都不得恢复。
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
- Reader/Pipeline 参数仍为 encoded前7/后3、holder最大7/5/3/2、稳定decode前2/后1、normal network/decode/upload=5/3/2。上一current的output retention与相对role正交；far static不得因静态证据越过稳定decode窗口，真实viewport静态页仍可获得一帧输出。
- current priority=1000；network/decode/upload各保留1个仅current可用的bounded handoff，transition=900不占保留槽。动态current depth<3时 speculative neighbor refill目标为0；静态current一帧即满足。current等source时仅真实viewport transition可先取1帧。
- origin `TaskControl`继续贯穿 DownloadJob → ArtifactCacheTransport → Loader/source request-plan → runtime。Venera保持真实单invocation：controlled pressure floor=780且差值至少40才请求requestId cancellation，旧JavaScript触发`finished(requestId)`后才转交唯一permit；previous不得制造第二JS context。origin trace现拆出`sourceRequestPlanMicros/sourceRequestPlanCacheHit/sourceHostOpenMicros/sourceOpenPath/sourceRetryUsed`，这些字段只用于观测。
- logical detach严格按真实 session transport state判定：`activeRun`覆盖restore/request-plan/open等待，不能代表receiving；只有 active `DownloadState.receiving` 可以降为priority 0保留。active queued/opening离窗后必须经NetLane TaskControl取消并等待物理退出。dev.185进一步把Reader previous=780设为normal-slot pressure floor：被普通槽阻塞时可以请求取消至少低40分的active victim，但previous不得使用current-only reserved handoff，必须等victim物理退出；retained receiving=0在无窗口压力时仍保留复用。
- dev.175–181 的 response abort、native锁/CRC、retained-receiving、controlled read-through继续有效。dev.182 的 raw-stream/single DownloadJob aggregation只属于owner清理；rhttp transport不得再次增加64/256 KiB聚合，不再作为首帧主性能解释；不得继续围绕64/256KiB猜首帧根因。
- Native identity保持 `zic-media-core-dev134-abi6-lib00121400`。
## 下一步真机优先验证
- 首先复测快速前后翻页：dev.185外层 previous admission应继续保持毫秒级；随后查看Venera request-plan gate，previous=780若比active低rank work高至少40分可请求取消，但只能在旧JS physical finished后启动。无真实pressure时`receivingRetained=true` priority0仍应短时复用，不得机械取消。
- 真机首要复测 current 首帧稳定性：观察 policyDecision 的 staticWarmDecodes/uploads 是否收敛到稳定decode角色/真实可见页，current浅水位期间是否停止 speculative neighbor refill，以及decode/upload current handoff是否避免后台长任务阻塞。
- Venera慢页直接按新增stage字段拆 execution：先比较`sourceRequestPlanMicros`与`sourceHostOpenMicros`，再决定追request-plan/JS还是rhttp/DNS/TLS/首包；同时继续记录cancel→native abort→JS finished，确认单上下文无物理重叠。不缩7/3、不增加Venera并发。
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
