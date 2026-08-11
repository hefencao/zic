# zic Implementation Plan
## P0：Image Transfer ownership 正式迁移
- dev.214完成scoped consumer claims；dev.215拆出Reader-local ingress projection；dev.216提升composition physical owner；dev.217先收口其调度回归：同一exact `DownloadId`的queued/active task key必须稳定，policy revision只能原位迁移priority，禁止重复task占用NetLane并撞击同一session/writer。
- 下一阶段先把source-confirmed relation + persisted verified page mapping + strong media identity归一为verified TransferKey-before-acquire，使已证明等价版本页在建立physical session前合流；再把chapter/whole-comic/prefetch改成同一owner上的demand aggregation。覆盖与冷启动证据未闭环前保留durable partial、artifact equivalence与session/takeover兼容路径。
## P0：Partial authority 单调性真机闭环
- dev.195 的playable partial单调性继续冻结：Range probe/full-body catch-up的取消、EOF或mismatch只能失败当前 network attempt，旧partial/Ingress不变；metadata损坏只丢网络知识。dev.196不改DownloadSession authority、DecodeSession、NetLane、network=5、1000/780、7/3、2/1、7/5/3/2，也不增加bandwidth scheduler/framing。
## P0：Current / Previous 真实执行槽真机闭环
- dev.192 真机首要比较`sourceRhttpProgressMaxGapMicros/sourceRhttpProgressLeadBytesMax`与`sourceRhttpBodyMaxGapMicros/maxChunkGapMicros`：若receive-progress与raw body同时长gap，优先归因源/CDN/HTTP链路；若progress持续前进但body长期滞后且lead显著扩大，再调查rhttp FFI/Dart Stream delivery/backpressure。不得用该diagnostics直接驱动scheduler。
- dev.191 cache已在15:08 trace明显命中：多数page为4次逻辑bridge call中的3 hit/1 origin。后续只有cache hit重新退化时才回查identity/Cookie/header；当前主线转向最终图片body持续传输。
- dev.190 后首次本地 Flutter/Dart 构建仍需确认 `runtime_source_adapter.dart` 不再出现 `onTiming` named-parameter 半迁移；若还有 runtime source adapter 编译错误，先检查私有函数类型/constructor 注入的一致性，不把 resource-plan diagnostics 扩到通用 browse/details invoke。
- 复测 dev.186 Venera nested pressure：外层 previous 660→780 到 `downloadStarted` 应继续维持毫秒级；若其随后被单 invocation request-plan gate挡住，780可请求取消至少低40分的 active controlled invocation，但必须等旧 JavaScript `finished(requestId)` 后才开始，`maxActive`始终1。
- 使用plan/cache/host-open字段继续确认连接阶段；持续传输阶段新增`sourceHostHttpVersion/sourceHostRemoteIpHash/sourceRhttpProgress*/sourceRhttpBody*`与现有`sourceRead` bytes/chunks/gap。只有设备证据同时证明并发active streams损害current且底层pause能真实形成网络backpressure，才考虑NetLane-owned transfer pressure；不得建立Reader bandwidth scheduler。
- 同时复测短时 N→N+1→N：没有真实 in-window pressure时，已 receiving 的 retained=0仍应复用原transport，不得因为新增 normal pressure能力退化为每次离窗cancel/reopen；只有真实 previous/更高 normal work等待普通槽时才让槽。

## P0：Current 首帧 policy/execution 真机闭环

- 首先验证 current bootstrap：动态 current 未达到3帧前，speculative next/next2/previous 不应产生实际 decode refill；current 等 source 时只允许真实 viewport transition 先取1帧。trace 应显示 staticWarm 不再把 near/far 7/3 encoded页扩成 decode/upload。
- network/decode/upload normal concurrency 继续为5/3/2，三条 lane 各有1个 current-only reserved handoff；transition=900 不占该槽。快速切页时 current 不得等待低优先级高分辨率 decode/upload自然完成。
- Venera current pressure 取消旧 prefetch 时，先按 requestId 断开 native HTTP；Dart single-context permit 只能在旧 JavaScript `finished(requestId)` 后转交。真机 trace 若 current origin仍长尾，再拆 request-plan/JS/onImageLoad/HTTP-open各阶段，而不是继续修改字节chunk或缩7/3。
- dev.182 的 rhttp framing 修改仅作为 duplicate-owner 清理记录，不作为首帧性能主解释；`DownloadJob` 继续是唯一 page-body aggregation owner。

## P0：迁移 / 同源版本 / 更新提示真机闭环

- 在 source card 已入书架时确认左上显示书架图标并变暗；存在章节 `sourceUpdateAt` 或 projected confirmed successor relation 时右上显示独立感叹号。点击同源更新提示应直接打开来源确认的最新 successor，不得把 successor 自动加入书架。
- 从详情 AppBar 打开“迁移漫画源”：同源只展示 `ComicVersionSource/ComicVersionRelationStore` 已确认版本并提供“查看/迁移”；跨源可搜索同名候选或手填原生 ID。所有迁移必须进入同一个比较确认，sequence-only 不复制状态。
- E-Hentai/Venera 版本更新验证 raw locator、canonical identity、SavedComic/偏好别名：迁移到 successor 后旧 raw alias不得继续显示书架标志；查看版本不得改写阅读历史/版本关系。

## P0：Source Browse 封面 owner 与筛选入口真机闭环

- 首先复测 Venera、18comic、roumanwu 普通 browse 与 Mihon filter view：不得再出现 `runtime request arguments do not match operation`；普通 browse应显式传 `useFilters=false`，筛选视图传 true。若仍失败，先检查 operation/arguments wire shape，不绕过 validator或增加 source特判。
- 对同一漫画执行“漫画源列表首帧 → 打开详情 → 返回列表 → catalog后台 refresh/普通分页更新”，确认 canonical cover URI未变化时不产生新的 `cover-load-start`，也不出现 presentation decode重启；只有显式来源 artwork刷新或该卡片自身 URI/identity变化可以换 source。
- 记录 `source-cover:<sourceId>\0<canonicalComicId>` 的 `cover-load-start/source-ready/first-frame/decode-failed` trace，确认 browse projection `changed=true` 与详情 metadata更新不会成为 artwork revision。
- Mihon/source筛选以真实 `getFilterList()` 为唯一 schema owner：非空时分类栏按“最新 → 热门 → 筛选”显示，空列表不发明入口；bridge完整支持官方 8 类 Filter及插件自定义子类，筛选面板以类型化 `filterState`回传 Text/Sort等状态。首次默认 section仍由当前展示排序第一项决定，catalog cache不得恢复导航默认值。
- 真机验证“热门 → 筛选 → 直接应用默认值/选择最新排序”：焦点必须切到“筛选”，请求必须走 filter mode且 section为空；重新点击“热门/最新”才退出 filter view。验证 source card在详情加入/移出书架后立即投影左上书架图标+变暗状态。
- 对多章节漫画分别执行“只下载单章”和“下载整本”：任意已有 cache不得产生完成勾；单章命令真正完成后只显示空心勾，整本 queue complete后显示绿色实心勾，进入详情后对应临时标记立即消失。
- 用 raw locator发生变化但 canonical identity不变的 fixture/设备数据确认 Sliver child State不重建；若同一页出现 canonical alias重复，先在 catalog projection解决重复，不回退到 mutable raw locator作为 owner key。

## P0：Retained Artwork 生命周期与失效边界真机闭环

- 在 source browse 连续加载大量 transient artwork、触发 storage自动容量整理和手动“整理缓存”后，已进入 library/history/details 的 retained cover必须仍能冷命中；统计中 retainedBytes/Entries不得随 transient trim下降。
- 分别执行详情下拉 metadata refresh、章节目录刷新和 Reader progress更新，确认这些操作不删除 retained cover；只有精确 artwork revision/force refresh、整漫画资源删除或用户显式清缓存可以删除。
- 对同一封面先由 source browse以 transient写入，再从 history/details请求，确认同一个 canonical key只发生 retention promotion，不创建第二文件、第二 namespace或第二下载。
- 在完整 Flutter/Dart工具链执行 analyzer和 resource_cache/storage/catalog受影响 tests，重点确认 dev.165误删的 maintenance类型已恢复且没有恢复旧 file-path borrowing API。

## P0：Artwork 生命周期与更新语义真机闭环

- 使用本轮 trace 中曾“durableCacheFile → FirstFrame → 数分钟后 DecodeFailed”的同一批封面复测；在首页/Reader往返、内存压力和 response cache trim后，既有 ImageProvider必须继续显示，不得因为 cache-owned `.bin` 被删除而悬空。不得恢复 presentation retry/evict/watchdog。
- 同一 durable cover冷启动命中时确认 gateway仍在 source激活前成功返回；trace可保留 `durableCacheFile`作为来源 provenance，但实际 provider必须是自持有 bytes而非 cache path。
- Home updates分别验证四类：未入书架+有阅读历史、未入书架+已检测 source变化、已入书架但无 source变化、已入书架且检测到新章节/新版本；只有最后一类显示。阅读进度和普通 metadata刷新不得改变 update signal。
- 首次把此前未入书架漫画加入书架时，加入前已发现的 version/chapter signal不得被当作“新更新”；之后再次检测到真实 source变化才进入更新。

## P0：WNACG HTTP 媒体与终止失败真机闭环

- 用 `mihon:6551136894818591762` 重新打开 WNACG 列表、详情和 Reader，确认 `http://img*.wnimg*.ru/...` 封面与正文由原 source request成功返回；不得新增域名白名单、URL改写或第二 transport。
- 故意制造一个 non-retryable source failure，确认每个稳定 demand只产生一次 terminal failure，不再出现同一 DownloadId 数百次 `downloadStarted/taskFailed`；再制造 transient `ErrorCode.network` 验证有界 retry后成功/终止。
- 新 source-card trace应携带 `errorCode/errorMessage`；若封面仍失败，先区分 runtime/network policy与 decoder，不恢复 Presentation retry。

## P0：网络 UA / client / cache ownership 真机闭环
- 在完整 Flutter/Dart 工具链执行 analyzer，确认 dev.161→162 删除 `loadBytes`、split chapter resource setter 与 catalog artwork facade 后没有遗漏调用方；重点覆盖 `demo_home_source_compat`、`source_resource_gateway`、downloads 与 catalog tests。
- 真机/fixture 同时覆盖完整字节 fallback 与 streaming range path，确认二者使用同一 source-resolved request plan；不得出现 full-byte 直接调用 raw source transport或 metadata/artwork 走 page-body bypass。

- 在设置中切换自定义 User-Agent后分别验证通用 HTTP、普通 source WebView、Reader fallback与插件仓库请求；确认 source显式 UA和 Mihon browser-session UA仍优先，不被全局值覆盖。
- 对 Mihon/Venera source记录 host replay / source-owned fallback原因；redirect、`Set-Cookie`、未知 client wrapper和非媒体响应必须在进入 Pipeline前切回 source client，正常无状态媒体仍保持 host streaming。
- 全仓 trace核对 metadata/artwork只经 `ResourceCacheManager`；Reader page body只经 `pageResponseLoaderFor`进入 DownloadSession/artifact，不得出现新的 presentation裸 transport。
- 评估下一阶段 source-owned binary stream/file lease：目标是让必须使用 Mihon/Venera client的正文也直接以 pipe/file/stream进入统一 Pipeline，消除当前 runtime fallback整块 `Uint8List` seam；在没有明确二进制生命周期协议前不得把完整正文改成 JSON/Base64默认路径。


## P0：Home projection、Artwork namespace 与 Runtime generation 真机闭环

- 直接从详情进入 Reader并翻页后退出：Home阅读历史必须在 route返回后立即更新，不等待 SQLite durable barrier、不重新进入详情、不触发整库 reload；连续打开两个 Reader route时各自 final progress不得串位。
- 同一外部漫画执行 browse → details → history，记录 canonical comic identity与 cache origin；browse已写入的 `artwork-v2` durable cover必须被 details/history直接命中，不得出现 `artwork-v2:artwork-v2` 第二 namespace。
- 冷启动直接激活 `venera:ehentai`：若首次 Binder generation在 activation完成前 died/disconnected，Android runtime-service client最多保留原 pending activation跨一个新 generation；若新 generation仍死亡，导出 runtime process crash/LMK，不增加第三次重放或 Dart/plugin层 retry。
- 继续对 `home-history:<canonical identity>` 对齐 source/cache/decode trace。source可用但持续 `Failure` 时沿 request/transport本身调查，不再由 progress rebuild、source-ready retry或 cache namespace分裂掩盖。

## P0：Mihon目录、Venera生命周期与图片网络设备闭环

- Roumanwu：记录 `getMangaUpdate` 输入 raw SManga、详情结果和 chapter count；确认 compatibility shim 的 `fetchChapterList` 使用原始 manga，原 80章不会再被旧 durable manifest/错误 request identity刷新为0章。
- 禁漫天堂：升级后确认 Mihon details/chapter cache revision触发真实刷新；若 source仍返回单个完整 `SChapter`，保留其原始对象并采集 fresh trace，不再用标题/URL猜测。Cloudflare本轮不调整。
- 绅士漫画：分别验证 cover/page host直连与 `sourceMediaProtocolMismatch` compatibility fallback；确认非媒体 2xx在进入 decoder前被拒绝，正常媒体仍保持统一 host streaming。
- Venera：连续修改镜像/设置和完成 Web登录，确认 active source/session不被 replacement；安装超过8个混合外部插件，确认生产32-session上限下不会因第9个开始静默消失。

## P0：详情Artwork API与重复解码设备闭环

- 真机打开含大量预览/评论头像的详情页，确认普通 artwork每项只有一个 provider listener；裁剪/尺寸测量项只有一个显式 ImageStream listener，build/layout与 decode不因加载占位再挂第二个 Image。
- 对 cover/preview/avatar分别导出 gateway role/cache key，确认详情 loader显式透传 role且不会全部误写入 cover namespace。
- 在完整 Flutter工具链运行 analyzer与受影响 details/source-browser owner tests，确认 dev.157 artwork owner-cleanup 的所有调用方已一次迁完。

## P0：Reader热路径、Mihon章节与Artwork身份设备闭环

- 对比 dev.155 与当前版本的翻页/退出 Reader frame timing：确认每页 checkpoint只发送 isolate消息，不在 UI isolate执行 sqlite3/章节JSON解码，不逐页触发 Home rebuild；route返回后再完成 barrier/reload。
- 用同一 Mihon漫画在 browse、details、history记录 raw comicId、canonicalComicId和 cover locator；即使 SManga标题/简介/thumbnail/memo变化，三处必须命中同一 canonical artwork namespace。
- 在 source暂不可用时验证 warm `mihon:resource:`/HTTP(S) durable cover仍能显示；durable miss明确等待 source，绝不能调用 local file loader。

## P0：Cloudflare会话、详情路由与插件恢复设备闭环

- 在发生“验证接近完成又重新开始”的设备上确认验证 WebView使用 provider真实 UA；导出 handoff snapshot UA与 Mihon首个重试请求 UA，必须一致。若 challenge仍循环，继续检查 TLS/IP/站点策略，不得重新伪造 UA。
- 首次从漫画源进入远程详情并退出，再连续进入同一漫画；确认第二次及后续导航不被 comic route identity lock吞掉。Reader返回后详情/首页阅读历史应立即反映最终进度。
- 在插件 runtime未激活/激活失败时重启 App，确认阅读历史中已有 durable HTTP(S)封面仍可显示；durable miss才等待来源恢复。
- 使用旧 `installed.json.invalid`、残留 `.part`、上一代 `.bak` 和单条坏记录分别启动，确认有效插件自动恢复，坏记录只产生诊断；恢复后的 payload仍通过 hash、签名、ABI与 entry class验证。
- 在完整 Android release工具链中构建 minified APK，并用 `jadx`/`dexdump`确认 `dev.zic.network.SourceVerificationRequiredException` 保持原始名称；随后在真机重新激活 Mihon共享扩展。

## P0：Mihon 插件识别设备闭环

- 绅士漫画用真实 page `imageRequest(page)` 验证 method/Referer/Cookie/body request plan与 Mihon宿主一致；能拿到页数后，host transport必须直接得到可读图片，不得改为完整RPC正文。
- 已激活插件连续执行 WebView验证、设置修改和同包更新；故意让 replacement activation失败，旧插件必须继续出现在 activeSources并可请求。
- 使用直接字符串和 `@string/...` metadata 的真实 Mihon APK分别验证 extensionLib、单入口和多入口 class解析。
- 验证插件重启时 common runtime预检不再要求内部 `AndroidBrowserCookieSession`，并确认 Cookie snapshot reset仍在首个真实 request前生效。
- 对无法识别的 APK导出 package、metadata key、ABI和 entry class诊断，不能静默表现为“未检测到”。

## P0：身份、同源更新与验证设备闭环

- 使用真实 Venera/E-Hentai successor 检查详情“有新版本”、统一比较确认和 Reader 首次提醒；确认换 successor 后再次提醒。
- 验证同源迁移只复制 exact chapter identity；sequence-only 候选不复制阅读状态或 artifact。
- 在禁漫天堂真机验证两条分支：真实 `challenge-error-*` challenge进入 WebView并完成 handoff；仅含 Cloudflare challenge脚本/普通403的响应不产生 `sourceVerificationRequired`。确认 WebView不会在 Cloudflare尚未完成时因一次 `onPageFinished` 提前返回；Turnstile/JS challenge存在期间持续停留，最终页面连续稳定无 challenge后才自动保存完整 Cookie/UA snapshot并返回，且不要求生成新 `cf_clearance`。
- 使用真实 Mihon 1.4/1.6扩展验证宿主调用顺序：1.6先 `getMangaUpdate(...fetchChapters=true)` / `getPageList(SChapter)`，1.4仅能力缺失时回退 legacy。用禁漫天堂确认 source返回的每个完整 SChapter原样保留且不按相同 URL折叠；Roumanwu原80章不得再因错误入口刷新成0章。

## P0：来源投影、Cloudflare 与封面身份设备闭环

- 在 Venera/Mihon 多次切换且目标请求失败时，确认页面在同一帧切换为目标缓存或目标 loading/error，绝不显示旧 source 卡片。
- 对禁漫天堂执行强制刷新，确认只有真实 Cloudflare challenge 产生 `sourceVerificationRequired`；普通 403/timeout/解析错误保持原分类，主/兼容 interceptor 行为一致。
- 完成一次手动或自动验证后故意保持 runtime失败，再连续点击刷新/重试，确认不会再次自动跳 WebView；手动“网页验证”仍可重复打开。
- 验证打开浏览器后立即取消/Activity中断不会擦除此前同站点/同 UA有效 snapshot；确认 snapshot revision仅在成功 capture时前进。
- 让同一漫画同时进入更新、书架和历史，并改变 raw Mihon alias、resume chapter、Home enrichment 和前后台状态；确认 canonical cover State 不被销毁，成功封面不会因 presentation rebuild再次请求。
- 分别制造 source loader错误与 Flutter decode错误；确认 presentation稳定停在占位且不启动 timer/watchdog/resume retry，也不 `ImageCache.evict`；显式来源刷新后才允许发起新请求。

本文件只列未完成工作。

- 用长阅读会话记录 progress writer事务次数：连续翻页期间不得每页写 SQLite；停止约 8 秒后提交一次，持续活跃最多约 30 秒提交一次。Reader pop动画不得等待该 durable提交；返回后 Home/详情只更新当前 progress投影，不扫描整库。
## P0：Transition 首帧与切页设备闭环

- 验证拖动建立 transition 后，即使 current holder 为 0，目标页也先产生独立首帧。
- 确认目标页网络不等待 current source sealed、完整下载或 holder depth。
- 验证 transition 首帧后 current 基础水位先于 transition 深水位，且反向拖动不重建同一 identity。

## P0：Venera requestId 物理取消闭环

- dev.189真机复测current-only动态preemption：780↔900 transition抖动不得再触发plan cancel；等待中的任务真正跨入1000时仍应对低rank active plan形成一次pressure，并等待旧JS真实`finished(requestId)`后转交唯一permit。用新增gate/runtime/hook/bridge-network字段直接定位剩余秒级plan owner；不预解析整章且不增加第二JS context。
- 对取消中的 URLConnection 与 DNS-fallback response body验证 request-scoped `InputStream.close()` 可使 blocking read及时退出；同时验证正常未取消请求完整 body、Cookie/header行为不变。
- 验证 Venera plugin `delay` Promise 正常计时、cancel立即 reject，且一个 requestId取消不会清除其它 requestId timer。不得恢复 native `Thread.sleep`。

## P0：远程 Animated WebP 连续性

- 对比 transport chunk、64 KiB session append、source revision、decode batch、holder depth、deadline 和 present cadence。
- 若 current 仍断粮，只在 NetLane ranking、重复 request/source、partial wake、decode producer 或 upload deadline 内定位；不得恢复 FlowGate/startup-buffer、缩小 7/3 或降低速度。
- 真机连续快速前后翻页验证 VibeVenera retained-receiving语义：离开 encoded 7/3的 active receiving只降为priority 0，短时返回必须复用同一transport；queued undemanded可取消。新的current真正受阻时，NetLane bounded saturated preemption与Venera单上下文pressure-preemption应使低rank receiving让路。若仍阻塞，沿“current等待→实际占用Venera permit的requestId→runtime cancel→host response退出”定位，不再用detach即cancel制造重复下载。

## P0：下载管理 Route-First

- 从首页点击“下载管理”必须先绘制页面，再做 whole queue ready、chapter `inspectMany()`与 cache usage检查；已有 Home snapshot应立即可见。用阻塞 bulk-inspect fixture验证首帧不依赖扫描完成。

## P0：后台重入生命周期

- 验证两分钟内同章重入命中 `readerSessionReused`，不重新创建整组 Download/Source/Decode session。
- 确认 used texture 仍重新创建，idle resource retention 不跨 Reader 复用 SurfaceProducer。
- 验证 TTL、source revision变化和第二章节淘汰后的完整 dispose。
## P0：Flutter/Android 工具链闭环

- dev.212真机验证：继续确认 `verifiedEquivalentReuse=true` 命中率；短时间反复进入同一详情/Reader时版本 discovery 仍可运行，但fresh mapping不应反复出现完整 `version-page-mapping-warmed`/request-plan重验证。超过freshness窗口或发现新relation后应重新验证mapping。 dev.213真机压力验证：在版本A仍有active partial/origin时让等价版本B完成full；A若该页`verifiedEquivalentCandidates>0`，应出现`verified-equivalent-promotion-takeover`并从原committed boundary转本地equivalent full，不应继续把尾部从origin下载。若重复下载页的`verifiedEquivalentCandidates=0`，转入page mapping/offset覆盖审计，不升级为session partial共享。
- dev.211真机验证：冷启动Reader继续不得等待source-version resolver；已有mapping时应先出现`version-artifact-equivalence-restored`。让相关版本在另一Reader仍存活时继续promote新artifact，旧版后续未启动页应出现`verifiedEquivalentReuse=true`并直接走artifact cache，不要求退出重进再次扫描。E-Hentai旧版confirmed successor的`!`继续验证。partial保持durable inactive边界，并在续传trace看到validatorless overlap验证而非继承旧ETag。
- 纵向静态图片持续上下拖动时，异步页面比例收敛不得再触发anchor `jumpTo`造成短距离回拉；旋转、真实viewport/DPR变化、vertical stitch切换与显式跳页仍需验证位置连续。
- 真机优先验证 dev.206 ownership：快速退出/重进同chapter应直接复用retained PipelineReaderSession，不出现partial durable store/restore；只有session真实evict/dispose后新session才出现`session-partial-handoff` restored且`downloadStarted.committedLength>0`。已有partial动画重入必须从frame0立即播放，约30帧循环继续只属于DecodeSession。Venera cold resolver应不再出现Kotlin HttpURLConnection owner，并验证requestId cancel、Cookie/manual redirect与resolver rhttp复用。
- 运行 Rust/Android target 与 JNI symbol验证，确认 APK 中 native build identity正确。

## P1：漫画源、过滤与详情预览设备闭环

- 真机验证 Mihon Popular/Latest 与 Venera 多 explore/category section 的顺序、分页和 section identity。
- 验证浮动搜索历史持久化；展开状态下系统返回、面板上下拖动和内容列表滚动均先收起搜索并释放焦点。
- 使用真实 Mihon 扩展验证 `getFilterList()` 中 CheckBox、TriState、Select 与 Group 子项的标签、默认值和回传值；未支持的自定义 Filter 不得阻塞普通浏览。
- 验证漫画源 cache-first/background-refresh 与数据未变化时列表、封面不闪烁；下拉达到阈值后保留现有内容执行强制来源刷新。
- 在窄屏、常见竖屏、宽屏与极端横纵比预览上确认完整行尽量占满可用宽度、折叠/展开第一行一致、完整行铺满媒体宽度、稀疏末行面积不超过参考完整行 2.4 倍、每行数量规则和屏幕高度 90% 上限同时成立。
- 制造 source Future失败、decoder错误和离屏未绘制三种状态，确认 presentation都稳定失败而不自动重启；随后显式刷新来源，确认由统一 gateway重新加载且不会清空其它封面缓存。

## P1：首页与缓存身份

- 设备验证本轮 primary projection 到第一封面请求的时序，并确认 native prewarm、整本队列 restore、外部插件 activation 不再位于 Home 首帧关键路径。
- 设备验证首页多封面快慢混合时的渐进显示：确认 `homeCoverFirstFrame` 按封面独立推进，不被 durable response 串行写入或其它慢封面形成全局等待。
- 验证封面 URL/token 变化仍命中 stable cover key，verified artifact alias不会污染无证据页面。
- 设备验证已有 raw durable cover hit 时的 source-independent 分流：首屏不触发插件资源
  请求；同时确认已持久化 canonical alias 的同源 raw ID 在插件未激活时只显示一张书架卡片，
  且未访问书架页不创建额外 cover loader。
