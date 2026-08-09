# zic Implementation Status

**源码版本：** `0.31.0-dev.181`
**App build：** `0.31.0+181`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- 构建/依赖基线为 Dart>=3.12、Flutter>=3.44、AGP9.3.1、Gradle9.5.0、compileSdk37；Gradle daemon按用户本地环境要求使用OpenJDK25，但Android Java/Kotlin class-file target继续17。workspace直接 `test`约束为`^1.25.0`以兼容Flutter3.44固定的test_api解析。五个本地Android Flutter插件不再自行apply KGP，稳定Flutter兼容层仍保持 `android.builtInKotlin=false/android.newDsl=false`；Mihon ABI兼容依赖继续固定。
- 外部漫画媒体生产host使用 `downloads_bridge/RhttpSourceResourceDirectTransport` + rhttp 0.18.0：source request-plan、NetLane、DownloadSession/artifact所有权不变；Rust/rhttp只执行已规范化单次请求并观察同一个`TaskControl`。网络packet通过前缀验证后首块聚合约64KiB、后续约256KiB再交给Pipeline，避免1–16KiB小包逐个触发Dart commit；pure `downloads`仍以Dart HttpClient作为非Flutter/test默认。后台首帧后预热rhttp runtime。
- dev.175建立了`DownloadJob/LoaderTransport/source-plan/Venera`的TaskControl能力，但dev.181设备证据与生产composition审计发现外层`ArtifactCacheTransport`仍会擦除该能力。dev.181将read-through cache也升级为`ControlledTransport`，cache miss向controlled fallback传递同一CancelToken；至此生产Reader origin链才真正保持动态priority/cancellation。Venera仍单 invocation，permit transfer按实时priority选择，active prefetch取消下沉到既有`cancel(requestId)`。
- dev.175 同时收口下载卡顿的 native锁反转：`zic_cursor_decode_next()` 在 source读锁内只准备 demux/单帧压缩 fragment，WebP decode、缩放、合成和 canvas copy移到锁外；Dart主 isolate同步 append不再等待后台 worker完整解码。7/3、2/1、5/3/2及 network5+reserved1均不变。
- 下载管理页采用 route-first projection：Navigator进入后先显示 Home现有 chapter download snapshot与 whole-comic queue snapshot；`wholeComicDownloads.ready`、`inspectMany()`和 cache usage检查在首帧之后刷新。逐 entry `Future.wait(inspect)`与 initState microtask扫描已删除。
- dev.176 继续收口 transport/body与artifact热路径：prefetched host response在完整stream生命周期绑定 `TaskControl`，outer consumer取消必须abort底层 `HttpClientResponse`；partial artifact append不再逐chunk同步计算CRC32，seal/restore时在 isolate一次性rehash。checksum完整性、7/3、2/1、5/3/2及network5+reserved1均不变。
- dev.177保留VibeVenera receiving生命周期：普通logical detach不取消active transfer，短时回切原位提权；current pressure才抢占。dev.180进一步把“上一current output retention”从相对role拆出：相邻旧current仍按真实offset成为previous/next并继续download/decode，`retainedIndex`只叠加last-output upload；大跳后若旧页已离开7/3窗口则只保output，不制造冗余网络/解码。
- External plugin browse wire contract 已与 dev.171 filter mode 对齐：typed factory、runtime validator、source adapter均显式认识 `useFilters`；schema v1旧请求允许缺省该新增字段并按 false解释，但未知字段/错误类型继续严格拒绝。发布 gate在无 Dart SDK环境也检查 protocol/adapter/Mihon driver四端一致。
- 漫画源筛选拥有独立 filter-view request mode：非空 schema时“筛选”是可选中焦点；直接应用未修改面板也会以插件默认 `FilterList`执行 filtered browse。空 override不再等于普通 section；filter mode的 Catalog key/runtime payload单独编码，且不继承 Latest/Popular section。
- 漫画源卡片书架状态由 Home canonical `ComicPreference`投影：已入书架封面左上显示书架图标并变暗，不建立 source-page shelf store；`sourceUpdateAt`作为独立右上感叹号提示。Home/书架下载完成勾改为显式命令反馈：单章完成空心勾、整本 queue complete绿色实心勾，进入详情消费；持久 chapter cache不再直接生成完成勾。
- 漫画源 browse projection 与 artwork presentation 已解耦：目录分页/后台刷新只更新 metadata，不再用全局 `_contentRevision` 强制所有 `_RemoteImage` 重新加载；封面只在自身 URI 变化或用户显式来源刷新时更换 source。Sliver child owner key 使用 canonical comic identity，mutable raw locator只保留 source调用/交互定位。
- 漫画源筛选改为来源真实 `FilterList` schema/state contract：Mihon bridge按官方 Filter基类识别插件自定义子类，完整保留 Header/Separator/Select/Text/CheckBox/TriState/Group/Sort与 Group层次；只有非空 schema才显示“筛选”，用户修改以类型化 `filterState` override进入 search request。
- durable artwork persistence 已拆分为同一 owner 下的 `transient/retained` 生命周期：source browse/preview继续受 96项/32 MiB transient LRU、TTL及 maintenance target约束；library/history/details cover在同一 canonical `ResourceCacheKey` 上晋升 retained，不再参与容量/TTL淘汰。晋升只改变持久生命周期元数据，不创建第二 cache namespace。
- comic刷新失效已从 artwork 解耦：`invalidateComicMetadata` 只失效 details/chapter metadata，不再按整个 comic namespace删除 image bytes；只有 `invalidateAllComicResources`、精确 artwork force/revision或用户清缓存可删除 retained cover。
- dev.165误删的 `ResourceCacheByteStoreUsage/TrimReport/Maintenance` 纯维护契约已恢复；storage maintenance实现继续可统计/整理 transient durable responses，但旧 `PersistedResourceFile/ResourceCacheByteStoreFileAccess/locate()` 文件借用 API保持删除。
- Home可见 library projection 与 durable mutation已收成 `HomeLibrarySession` write-through边界：chapter/SavedComic写入后同一次操作立即更新 Home；Reader page callback只 enqueue checkpoint，每个 route局部持有 final progress并在返回后只发布一次，不再依赖详情页退出或整库 reload。
- `HomeLibrarySession.reload()` 以 projection revision拒绝旧 entries/SavedComic snapshot覆盖 enrichment期间更晚的 write-through更新，避免 history在并发 reload结束时回退。
- External artwork基础 schema revision唯一属于 `resource_cache/ComicSourceResourceGateway`。browse/details/history使用同一 `artwork-v2` namespace；gateway参数只允许额外 `contentRevision`，Home/详情不再把 `artwork-v2` 重复拼成 `artwork-v2:artwork-v2`。local artwork直接复用同一个 schema revision。
- response cache不再把可由 LRU/TTL/invalidate删除的持久文件路径暴露给 artwork presentation。durable artwork命中先物化为 `MemoryEncodedResourceSource` 自持有 bytes；`FileEncodedResourceSource` 类型只能表示稳定本地文件。已删除 file-locate/borrow facade，避免已显示首帧在 cache trim后再次 decode 时悬空。
- Home“更新漫画”使用独立 `SavedComicRecord.sourceUpdateAt`：仅 shelf + source-confirmed update进入。已有章节目录发生变化或首次发现新 successor/version才推进；阅读 progress、普通 metadata刷新和未入书架浏览不推进。远程无偏好 primary projection默认 `inShelf=false`，首次加入书架清理加入前 update signal。
- 初次 Venera/Mihon activation 的 Binder generation连续性已下沉到 Android `PluginRuntimeServiceClient`：仅 pending activation可跨一个 `runtime-service-died/disconnected` generation；Dart backend删除初次 activation重放，session invocation与业务失败仍按原 owner处理。
- Home外部封面继续把 live source readiness作为显式加载依赖：首屏早于 plugin ready且 warm cache miss时，失败 Future只在对应 source从 unavailable→available后重新求值；普通 progress/enrichment rebuild不重试。历史/更新横向 Sliver直接 child使用 `section + canonical comic identity` 稳定 key并提供 reorder index callback。
- debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0` 和 `versionCode=179`。
- 首页先发布章节投影与 SavedComic primary 数据，封面不等待分类、偏好和阅读状态 enrichment。
- 冷启动先呈现 App/Bootstrap；native media prewarm、整本队列 restore 和外部插件 activation不阻塞 Home primary，外部 source ready 后增量接入。
- artwork资源恢复唯一属于 `ComicSourceResourceGateway/ResourceCacheManager`。Home、书架、漫画源和详情 presentation 已删除定时 retry、first-frame watchdog、App resume自动 retry、全局 ImageCache eviction和 App级短时 Future join；详情统一使用 `ComicDetailsArtworkLoader` 并显式传递 cover/preview/avatar role。普通 artwork直接复用 `StableArtworkImage`；需要裁剪/尺寸测量时只有一个显式 ImageStream listener，不再同时创建第二个 `Image`。
- 外部 artwork 的 raw comicId只保留 runtime locator语义；durable cover/preview namespace使用来源 canonical comic identity。Home、漫画源、详情与迁移统一经 `ComicSourceResourceGateway`，`mihon:resource:` 不再误入本地文件 loader；gateway先查 source-independent durable cache，miss后才要求 active source。
- 详情页恢复通用“迁移漫画源”AppBar入口，并与现有同源版本能力统一到一个迁移 owner：同源确认版本在迁移面板提供“查看/迁移”，跨源标题搜索只发现候选；所有迁移继续进入严格比较确认且只复制 exact chapter状态。漫画源卡片左上书架图标+变暗只投影 shelf membership，右上感叹号投影 `sourceUpdateAt`；点击确认同源更新可直接查看 successor。
- App-owned modal panel 的操作行统一使用左下角 X 关闭，右侧保留确认/保存/删除动作，
  已移除取消文字按钮。
- Venera 运行时登录请求已兼容 Android 解码后的嵌套 Map，不再把 credentials/cookies/web
  登录参数错误判为 `runtime-request-invalid`。详情 manifest 已接入 Venera `subId`、首批
  thumbnails/comments；支持的来源显示预览栏、评论栏、分页评论页和回复页，图片仍走
  统一 artwork cache，未声明能力的来源不会触发对应插件请求。
- 漫画源浏览页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态仅以 chip 背景色区分，不显示 JS/插件图标。首次进入来源默认选择 Presentation当前排序的第一项；当前标准排序为“最新 → 热门”，catalog最近 projection不再反向恢复 section/query/filter UI状态，只有当前精确请求缓存可直接投影。页码位于滚动尾部，左下浮动搜索只保留 query/持久历史；展开搜索优先消费返回和垂直滑动手势。`FilterableBrowsableComicSource` 不再另设 `supportsSearchFilters`；是否显示“筛选”只取决于该 source实际返回的非空 schema。Mihon自定义 Filter子类通过官方基类 `isInstance` 识别，Text与 Sort状态不再丢失或降级为 opaque toggle ID。catalog后台刷新且数据不变时不重建 artwork；边缘下拉达到阈值后保留当前列表执行强制来源刷新。Mihon 已安装与仓库插件列表继续按声明/source metadata 的规范化语言筛选。
- 详情页与漫画源页共用同一个可见的顶部边缘下拉刷新组件：`onEdge`、位移 72、保留旧内容后台刷新。
- Android可见浏览器 Cookie snapshot以 `updatedAt` 为 revision。Cloudflare验证模式不再用插件/OkHttp静态 UA覆盖 WebView；当前 Android WebView provider的真实 UA与同站点 Cookie/localStorage写入同一 snapshot revision。Mihon `AndroidCookieJar` 同步导入该 revision的 Cookie，runtime application interceptor对同站点请求逐请求采用 snapshot UA，避免 clearance来自真实浏览器而 HTTP请求仍声明另一浏览器/平台。验证浏览器继续保留 dev.154 的稳定完成窗口与宽 challenge探针；手动或自动验证后若 runtime仍失败，普通刷新不再自动循环打开 WebView。验证返回后按稳定 source ID取得 replacement adapter。
- Mihon runtime 通过稳定 `AndroidCookieJar.resetBrowserSnapshotImports()` 清理进程内 browser-snapshot revision；`AndroidBrowserCookieSession` 不再是 plugin host直接依赖或 common runtime ABI项。APK metadata reader可解析字符串资源形式的 extensionLib/entry class，并支持多个 entry class分隔。设备发现合并系统包、应用列表与仓库 package name精确探测，逐 APK失败和扫描计数直接显示；页面打开会自动加载默认仓库以提供精确探测 identity。扫描仅覆盖系统共享 APK，Mihon 私有扩展需从 ZIC仓库安装。
- Mihon common runtime要求的 `SourceVerificationRequiredException` 已加入 network bridge consumer R8 keep规则；动态 ABI和 host在 minified Release中继续以同一原始类名共享 typed验证异常。门禁会从 required network class列表反查 keep覆盖。
- Catalog 的 `resolveComicWebUri` 装饰器与来源能力保持 `Uri?` 合同；来源无法提供详情 URL 时由调用方继续使用 descriptor website fallback。
- Reader progress保持 latest-wins有序 checkpoint，SQLite查询/章节JSON校验/写入位于独立 progress isolate + WAL connection。Reader热路径只入队；同章节 checkpoint停止更新约8秒时批量提交，持续阅读最多约30秒提交一次。Reader route不等待 durable barrier；返回后 Home只发布最终 progress内存投影一次，已挂载详情页只替换当前章节，不再全量 reload library。生命周期 checkpoint仍为 best effort。
- 来源漫画从 source页首次打开并持久化后，再次进入时外层 source route 已持有 raw comic identity；local SavedComic分支直接 `_pushComicDetails`，不再嵌套 `_openComicDetails` 重申请相同锁，因此不会静默吞掉第二次导航。
- Home阅读历史、详情和漫画源使用同一 external artwork gateway/cache identity；HTTP(S) 与 `mihon:resource:` 等插件 locator即使 source尚未激活也先查 canonical durable cache，只有 miss才解析 source。
- 外部插件 manifest按记录容错并保留上一代 `.bak`；启动可从 `.bak`、`.part` 或旧 `.invalid`恢复有效记录与旧 sandbox payload路径，再重写主 manifest。恢复失败逐项展示，不再因一个坏记录清空全部插件。
- 外部插件 payload安装/升级使用事务式 runtime replacement；settings mutation 与 Venera Web登录原地作用于当前 runtime，不再创建 replacement session。通用 restart API已收口为 Mihon browser handoff专用能力。生产 external runtime显式允许 32 个 active session，避免测试默认 8成为插件消失上限。共享媒体 transport不再注入 Venera UA；Mihon host直连若 2xx返回非图片前缀，会在进入 Pipeline前改走已有 source-owned runtime network兼容路径。
- 网络设置提供可编辑的全局 User-Agent fallback，默认 Android Chrome 150；composition 动态注入通用 HttpTransport、Reader/章节下载、插件仓库与 shared source host transport。source request显式 UA、Mihon browser-session UA继续优先。
- 生产网络 owner已收口：App presentation无直接 HTTP；shared host replay只接受无 redirect/无 `Set-Cookie` 的直接编码媒体，其他情况转 source-owned client。`ComicSourceResourceGateway` 是 raw source transport的唯一 App入口。metadata/artwork必须走 `ResourceCacheManager`；page-body cache bypass只属于 Reader/DownloadSession/artifact。 dev.162 后 full-byte `loadPageBytes` 与 streaming `pageResponseLoaderFor` 共用同一 response loader；章节下载只接受原子 `ChapterResourceAccess`，catalog 不再提供 artwork loader facade。
- Mihon 1.6 `CatalogueSource` shim不再依赖 `kotlinx.coroutines`，ABI asset generator无需额外 coroutine classpath；`lang`正确 override，details/chapters仍使用原始 SManga。
- Mihon chapter目录不再 synthetic/标题/URL去重。1.6/current先走 combined `getMangaUpdate`；ZIC `CatalogueSource` shim已对齐当前 Mihon：details与chapters都基于原始 `SManga`独立请求，legacy fallback的 `fetchChapterList`也使用原始 manga。正文 `getPageList(SChapter)`只在能力缺失时回退 `fetchPageList`。Mihon comic/chapter durable metadata升 revision，避免旧错误空/单目录继续命中。
- Cloudflare 主路径与兼容路径统一委托 typed detector；仅严格 403/503 challenge 映射 `sourceVerificationRequired`，没有隐藏 WebView 或消息文本判断。
- catalog response cache 使用稳定 source/comic/chapter identity 和结构 weight；页面正文不进入该缓存。
- Home“更新漫画”与阅读历史分离：更新集合只消费 `SavedComicRecord.sourceUpdateAt`，不消费 `updatedAt` 或 `ReadingProgress.updatedAt`；Reader checkpoint不逐页触发 Home rebuild，route返回后只用最终 `ReadingProgress`更新匹配的内存历史 entry一次。
- 详情预览保留完整 URI 作为单项绘制身份，但 artwork role/cache key 使用去 `@x/y` 的 base URI，
  同一原图的不同裁剪共享一份编码字节；Venera `loadThumbnails` 的首批与游标分页
  不再重复消费 `loadInfo` 缩略图；折叠与展开共用按原顺序生成的等面积布局；实际行内含横图时最多 2 张、纯竖图时最多 3 张；只在相邻三个候选内做最小局部重排，并受阅读设置的 1–8 项上限约束（默认 4）。完整行按全部媒体宽度反算尺寸，预览图片区不再叠加 Card 和水平 padding；稀疏末行最多放大到参考完整行面积的 2.4 倍；折叠高度取第一行，展开图片区域不超过屏幕高度 90%，居中箭头控制展开；点击预览项会将索引传入既有 Reader 路由；Venera
  `@x/y` 预览 URI 在保留绘制身份的同时按既有约定以去裁剪 URL 调用 `onThumbnailLoad`，封面、预览
  和来源缩略图失败时统一使用稳定伪随机的柔和纯色占位；预览绘制只显示 `@x/y` 指定的原图区域。
- ArtifactCacheManager 默认热字节 10 项/256 MiB，支持持久 backend、verified alias/rekey 和 foreground read join。
- Reader encoded window 为前 7/后 3；decode 角色为前 2/后 1；动态 holder 最大水位为 7/5/3/2。
- transition 覆盖率达到阈值后独立取得一帧，再恢复 current/neighbor staged refill；不存在 DownloadFlowGate、startup-buffer 或 holder-depth 网络资格门控。
- 页面网络由共享 NetLane 唯一调度：normal 5、current 高优先级保留槽 1、priority migration/preemption；local bucket 2、remote bucket 5。
- DownloadJob 首批约 16 KiB、后续约 64 KiB 合并 transport 小块；partial/resume、source growth 和 WebP prefix hints保持。
- holder-driven playback 在 successor 缺失时保持当前 output，使用 one-shot deadline wake；两个 decode isolate常驻，current 后续最多双帧批次。
- Android output 使用默认 platform channel、单 blit lane和普通 main-thread post；used texture 不跨 Reader 复用。
- Reader 资源会话最多保留 1 个 idle chapter、TTL 2 分钟；保留 resource session，释放 Reader binding、projection、playback wake 和 used texture。
- Native identity保持 `zic-media-core-dev134-abi6-lib00121400`；dev.175 修改 Rust 内部锁临界区与 WebP frame preparation/decode 分段，但不修改 FFI ABI/JNI identity。
- 核心文档已按 production code 重新对齐；Reader 综合决策见 ADR 0122，Home 冷启动与
  封面前台完成见 ADR 0123/0124。

## 当前开放问题

- 需在 dev.180 真机复测快速前后跨页：current N→N+1后N必须立即进入previous下载角色（首位priority780）与后1decode窗，同时可保留last output；反向切页同理。大跳页后远离7/3的旧current只能保output，不得继续生成download/decode。继续记录current pressure/preemption，但本轮不再改其策略。
- 需继续验证下载管理入口首帧与下载压力：点击首页“下载管理”应立即进入 route，后台 bulk/cache refresh只更新随后帧；Reader下载仍观察 `nativeIngressMicros/artifactWriteMicros/UI frame`，不恢复热路径CRC、不缩预下载窗口。
- 需用 dev.165 真机确认 Reader route返回后 Home history立即接收 final progress，不依赖详情页或整库 reload；连续 Reader route不得串用 final progress。
- 需用 dev.167 真机复现 source browse → details → back：browse metadata/background refresh不得令未变化的 card cover重新走 loader；raw locator变化但 canonical identity不变时 card State必须保留。retained cover压力验证继续沿 dev.166规则执行。
- 需验证 Home updates：未入书架漫画即使有阅读历史也不出现；已入书架但没有 source update signal也不出现；真实新章节/新版本检测后才出现。
- 需对同一外部漫画执行 browse→details→history，确认 browse已写入的 canonical `artwork-v2` durable cover被后两者直接命中，不再出现第二 revision namespace。source可用但仍 `Failure` 时继续沿真实 request/transport调查，不增加 artwork retry。
- 需在 dev.173 真机先确认 Venera/Mihon普通 browse 已恢复，再继续验证 WNACG、筛选/下载反馈和迁移/更新提示：列表封面与 Reader正文应不再出现 `CLEARTEXT communication ... not permitted`；同一稳定 page demand的确定性失败不得再产生数百次 download重提。
- 需真机确认 Venera `venera:ehentai` 初次 activation 在 Binder generation死亡时由 Android client保留 pending activation跨一个新 generation；若新 generation仍死亡，应采集 runtime process crash/kill 证据，而不是在 Dart/plugin层叠加重试。
- 目标设备仍需验证 transition 首帧、远程 WebP frame cadence、后台重入和首页首封面时序。
- 本轮首页冷启动修复仍需设备对比 `homeServicesReady`、`home-library-primary`、
  `homeCoverRequested`、各封面 `homeCoverSourceReady`/`homeCoverFirstFrame` 的真实间隔，
  并确认慢封面不会形成全局屏障；还需确认 raw durable hit 不触发插件资源请求，隐藏
  书架页不再产生重复首屏请求。
- Android APK 构建和真机生命周期验证未在当前环境执行。

- 详情和漫画源刷新结果由同一个 `AppPullToRefresh` 定位；简介使用 Card，评论 HTML 换行转为普通文本，“继续”区增加上下间距。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| current-code documentation consistency gate | Verified-static |
| dev.135–dev.180 受影响 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge + dev.164 PluginRuntimeServiceClient stub compile | Verified-toolchain |
| pinned libwebp host build/smoke | Unverified：当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` |
| 受影响 Flutter owner tests | Unverified：当前环境没有 Flutter SDK；已补 owner tests，未执行 |
| Flutter analyzer | Unverified：当前环境没有 Flutter/Dart SDK |
| Android debug/release split APK | Unverified：当前环境没有完整 Android SDK/NDK |
| 设备性能与生命周期 | Implemented；待设备复验 |
| Verified-device | 无新增结论 |
