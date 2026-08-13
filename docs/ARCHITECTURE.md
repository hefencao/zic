# zic Architecture
本文件描述当前生产代码的稳定所有权、依赖方向、数据流和生命周期。它不记录版本历史、单轮 Trace 数字、测试通过情况或待办事项。
## 1. 架构目标
- current 具有最高资源优先级，但目标页首帧不得依赖 current 的下载完成或 holder 深度。
- 同一稳定 identity 只有一个权威 request、session、artifact、cursor 和活动 writer。
- Download demand是consumer claim，不是物理transfer ownership：应用级`PersistentDownloadComposition`持有唯一`CompositionDownloadTransferRuntime`，其`DownloadTransferOwner`按exact `DownloadId`唯一拥有registry/writer/network/retry/hot partial；同一queued/active task的policy revision只能原位迁移priority并保持task identity。Reader current/prefetch与显式chapter command只attach scoped `TransferDemand`，whole-comic只聚合chapter command。priority只表达竞争顺序，required completion独立表达必须最终完成，取消只撤销自身claim；logical claim归零时already-admitted physical task保持同一task key、迁移到rank 0并在NetLane标记`demanded=false`；working-set detach本身不得cancel。NetLane把live `running` task与body-read `active` permit分开：DownloadJob在下一安全read boundary释放permit并park同一response/StreamIterator，normal pending只竞争释放后的permit，不得为了“腾5路”取消parked response。parked response由有界池管理，只有显式`parked-response-eviction`、current-only destructive preemption、真实failure/provider dispose才结束response；DownloadState、Range、Reader距离不得形成第二套detach/reclaim策略；尚未admit的queued task可直接移除。native `Ingress`、decode/upload/presentation保持Reader-local。physical session只声明transfer/residency：普通hot/partial从session artifact重放；`residentBodyBacked`表示正文由外部immutable authority重放而非session artifact副本，绝不等价于durable cache ownership。`ByteResponseBodyAuthority`显式区分source与`ArtifactCacheManager` body authority；source-resident promotion不会自动持久化，显式durable completion才通过composition consumer/source authority校验length/validators并materialize到唯一ArtifactCacheManager/store。late projection replay继续从cache或可重开source提供encoded bytes并服从共享artifact-read scheduler；异步late replay默认在追平authoritative committed boundary前保持source unpublished；但对已sniff为WebP的nonresident hot partial，新Reader可按decoder-owned playable/required/unresolved prefix contract先重放并发布最小可播放前缀，再在同一Reader-local native source上增量追平artifact suffix，只有稳定追平后才加入physical live fan-out。任何early publish后都禁止rebuild/reset替换已对decode可见的same-generation source；physical partial availability、Reader-local source visibility与network admission必须保持三个独立事实。 Reader-local source watch必须显式绑定当前physical DownloadSession/projection generation，不能只按logical DownloadId记“已监听”；logical id跨demand gap重解析到新physical generation时必须解绑旧projection、失效旧decode source-consumption/binding并从新projection重新wake。same DownloadId的新DownloadSession对象同样属于新physical generation，不得复用旧Reader-local Ingress/native source实例。physical async prepare若已从本地artifact/partial authority恢复到promoted或完整可本地完成状态，必须在provider transport lookup/lease与`downloadStarted`之前短路；`downloadStarted`只描述真实provider transport attempt，本地完成不得占用provider lifecycle。verified跨版本等价只允许在acquire前把尚未创建exact session的新claim加入既有direct verified physical authority；若proof同时命中多个既有owner，resolver按promoted、active writer/run、demanded、committed prefix及长度/priority稳定择优，复用其中一个而不创建第三owner，也绝不事后merge两个已存在session。source-resident且非artifact-cache authority的body不得跨版本join，弱证据仍不得进入physical identity。
- Reader navigation只提交 observation/用户命令并消费只读输出，不直接操作 transport/session/artifact/lane/frame/texture。slider scrub是实时navigation：thumb、页码与Reader viewport在`onChanged`中同步前进；但scrub中间态必须显式标记`Interaction.scrubbing`，Pipeline只允许当前页foreground download/decode/upload，不展开7/3 prefetch窗口；gesture end在同一最终页发布非scrub observation并恢复完整窗口。observation到pipeline必须经过enqueue/latest-wins边界，pipeline reconcile异常不得反向unwind ScrollNotification/page request；ReaderBinding必须先推进Reader-local viewport fact，并在reconcile成败后独立同步playback projection。`ReaderController`与requested/current page属于route/navigation owner，`DecodeTarget`只属于pipeline/media projection；MediaQuery/system UI导致target变化时只更新PipelineController target并在enqueue observation中从既有DemandPlan做增量diff，不得detach binding、清空download demand或重建navigation controller。
- 下载、解码、上传使用独立 scheduler；一个层的运行时状态不能成为另一层页面的资格门控。
- 平台能力由 composition root 原子注入；核心包不反向依赖 Widget、Android plugin 或具体 FFI 实现。
- 创建者关闭 owned 对象；外部注入能力不得被消费方误关闭。

## 2. 分层与依赖

```text
Presentation
  apps/app, local_media_ui, reader_runtime, reader
        |
Composition / platform adapters
  pipeline_native, downloads_bridge, storage_bridge,
  local_media_bridge, network_bridge, plugin_host_bridge,
  runtime_bridge, texture_bridge
        |
Policy / resource runtime
  pipeline, pipeline_runtime, downloads, sessions
        |
Domain / contracts
  domain, catalog, resource_cache, transport, storage,
  media, telemetry
        |
Native implementation
  bridge, native/media_core
```

依赖只能向下或指向稳定抽象。底层包不得读取 Widget、路由、App controller 或页面控件状态。

## 3. 包所有权

### `domain`

领域 identity、值对象和不可变实体。`TaskControl` 是 scheduler-owned work 跨层只读控制合同，只暴露 cancellation 与 priority；需要保持已admit工作实时rank的下层可选择观察scheduler-owned priority change，但只能重新评估既有执行资格，不能写priority或形成第二调度器；消费层不得借此拥有调度策略。不得依赖 UI、插件、网络、缓存、数据库或平台桥。

### `catalog`

漫画源、漫画/章节/page manifest、来源能力和 catalog cache identity。`CachedBrowsableComicSource` 只缓存 browse/details/chapter metadata，不拥有 artwork 加载；Reader 页面正文仍透传到统一 Pipeline。

### `resource_cache`

封面、详情、搜索、章节元数据等可重新获取响应的唯一缓存平面，拥有容量、TTL、分类预算、in-flight 合并、持久 byte store 和失效策略。

### `transport`

可取消、可分块的 encoded-byte transport、range、validator 和 response 合同。Reader page 使用可选 `ControlledTransport` 将 scheduler `TaskControl` 贯穿 cache read-through、source-plan、open与response body；任何transparent/read-through wrapper若下层支持controlled capability都必须保持同一control，不能因cache miss降级为普通`open()`。transport可中止自身请求但不拥有priority policy，也不得在请求真实退出前伪释放lane容量；prefix probe后outer stream取消仍必须abort底层response。它不拥有artifact、Reader demand或播放状态。

### `storage`

partial artifact、连续前缀、校验、seal、原子 promotion、索引和临时 workspace。对稳定 DownloadId，已经提交并成为 playback authority 的 partial prefix 单调不减；网络 attempt 重启、validator 缺失或 Range 被拒绝都不能删除、缩短或重建该 prefix。partial append只写入并推进长度，不在UI isolate逐chunk计算CRC；seal/restore在isolate rehash后提交权威checksum。它不决定页面角色或网络优先级。

### `downloads`

composition-owned `ArtifactCacheManager`、artifact transport/read scheduler、verified-equivalence proof、章节/整本持久下载与来源 transport 组合。页面 session 状态本身由 `sessions` 拥有。

### `media`

encoded source、cursor、frame、output、renderer 和只读 timing capability。它不选择页面角色或 scheduler 策略。

### `sessions`

`DownloadSession`、`DecodeSession`、`UploadSession`、registry、claim/lease、frame holder、playback timer、Net/Decode/Upload lane 和 `LiveCoordinator`。它是可变媒体状态的权威所有者。

### `pipeline`

把 `ReaderObs` 纯计算为角色窗口和 `DemandPlan`。它定义优先级、水位和 keep 集合，但不创建 transport、artifact、cursor 或 texture。

### `pipeline_runtime`

Reader 章节资源会话的唯一组合所有者。它把 demand reconcile 到 download/decode/upload session，发布 `PipelinePageStream`，管理 frame budget、共享 page download lane、artifact handoff 和短期资源会话 retention。

### `pipeline_native`

把 native source factory、cursor、frame uploader、output projector 和 prewarmer 作为原子 capability 注入 `pipeline_runtime`。核心 Pipeline 不直接创建具体 FFI 或 Android texture 实现。

### `reader_runtime` / `reader`

`reader` 提供 observation、导航和通用 Flutter Reader；`reader_runtime` 负责产品交互、尺寸投影和 `ReaderObs` 适配。二者都不拥有资源 session、缓存或 native handle。

### Home 冷启动组合

`apps/app` 的 Home 关键路径只等待能产生封面的本地库 primary 数据和内置来源。
进程级 native media prewarm 在 Bootstrap/App 呈现后后台运行；持久整本下载队列以
`ready` Future 恢复；已安装外部插件由 `ExternalPluginController.openDeferred` 先完成
manifest 准备，再在后台完成设备扩展发现和 runtime activation。Home 在插件 ready 后
增量替换 source projection，不重新拥有或复制资源缓存。

`HomeLibrarySession` 先发布 entries/SavedComic primary，交给 Flutter 完成一个可注入的
首帧边界，再读取 enrichment 和写入缺失默认值。已挂载 Home 的 chapter/SavedComic mutation
必须通过该 session write-through：durable store 仍负责持久化，session 在同一次成功写入后立即替换
可见投影，不能依赖后续详情页或全量 reload 追平第二状态。外部 artwork 的恢复/cache权威只有
`ComicSourceResourceGateway/ResourceCacheManager`：presentation取得一个不可变
`EncodedResourceSource` 后只建立一个 ImageProvider。response cache拥有的持久文件是可撤销实现细节，
不得把其路径借给 Flutter；跨 cache 边界必须物化为 presentation 自持有的 encoded bytes。只有导入的
稳定本地文件可使用 `FileEncodedResourceSource/FileImage`。Future/ImageStream失败保持稳定占位，
普通 rebuild、App resume、timer/watchdog或 ImageCache eviction都不得自动建立第二套请求。
首页 artwork 的冷 miss 在 encoded bytes 到达后可先返回 memory source，durable response
写入由 `ResourceCacheManager` 后台排队；同一批封面按卡片独立完成，不等待全部封面或
全部持久化写入。gateway以 source-confirmed canonical comic identity探测 durable artwork
namespace；命中时不解析 source、不创建 plugin transport，miss才进入真实 source loader。
raw Mihon locator继续只用于插件 request/chapter identity，不参与 durable artwork分区。未访问的
首页、书架、来源和杂项页由 lazy indexed page 保持未构建，避免隐藏导航页提前创建第二套
封面 loader；访问过的页面状态仍由该页面节点保留。

Home 的“更新漫画”投影只取已在书架且具有 source-confirmed update 的漫画。章节/目录更新由 `SavedComicRecord.sourceUpdateAt` 表示；同源版本更新由 `HomeLibrarySession.versionRelations` 中 source-confirmed predecessor→successor relation 的首次 `discoveredAt` 表示。两者是并列事实源，presentation 只读合并后的有效更新时间；版本关系不得再镜像写回 `sourceUpdateAt`，阅读进度也不得推进任一更新事实。
普通 metadata刷新、阅读进度与仅浏览记录都不产生更新。漫画源卡片从同一 Home/library 投影读取书架与更新事实：
左上书架标志+变暗只表示当前 raw/canonical comic已入书架；右上感叹号只提示该书架 comic有 source-confirmed update。阅读历史
单独按 `ReadingProgress.updatedAt` 投影。

### 详情页与来源迁移组合

`ComicDetails` 只把详情展示、阅读进度和用户命令投影到 Flutter；详情 AppBar 不重复显示
漫画标题，标题只在详情内容区出现。保存过阅读进度时，继续阅读命令直接调用既有
`onOpenChapter` facade，按钮和阅读历史是两个独立的 UI 投影，并位于章节总数行上方；详情页不创建第二个阅读器或
正文缓存。来源浏览、manifest/chapter 身份校验、状态迁移和 artifact 复用由
`_DemoHomeSourceMigration` 组合 owner 完成。

同源版本关系只来自来源 `ComicVersionSource` 或已持久化的 `ComicVersionRelationStore`；Venera/E-Hentai按来源关系生成版本，
不得用标题 `browse` 推断同源。通用“迁移漫画源”入口允许选择当前来源或其他已启用来源：跨源标题搜索只用于候选发现，
同源面板只展示来源确认的 successor/predecessor，并同时提供“查看”与“迁移”。查看直接打开目标 raw identity，不改变状态；
迁移无论同源/跨源都进入唯一 `ComicSourceMigrationPlan + showSourceMigrationComparison`，只有 exact chapter match复制偏好、阅读位置和已读状态。查看路由只使用 `source-version-view` **temporary route identity**；同源替换完成后新 raw locator成为实体并清理旧 alias preference/metadata。已确认同源版本或显式迁移的强 page identity + bounded offset证据必须注册为对称verified-equivalence；`ArtifactCacheManager`不再拥有directed hard alias/rekey，exact DownloadId始终是durable write authority。Reader关键路径只从durable mapping恢复equivalence，不得现场等待source request-plan；exact miss才读direct equivalent，physical复用只在composition demand acquire发生，artifact commit不发布takeover side effect。

漫画源页使用来源自身声明的 browse section：Mihon 映射 Popular/Latest，标准展示顺序为“最新 → 热门”，Venera 枚举 explore loader 与 category target；首次进入来源时默认 section必须由**当前展示顺序的第一项**决定，不能另写 `popular` 默认值，也不能让最近一次 catalog cache projection反向选择 UI。未来用户自定义排序若改变 Presentation顺序，同一排序 owner自然同时决定默认焦点。原生/Mihon/Venera 仅通过来源 chip 的背景色区分，不显示 JS/插件图标，也不占内容分类行。`FilterableBrowsableComicSource` 只投影来源真实 `FilterList`：空 schema即没有筛选入口，不另设容易漂移的 capability布尔值。Mihon bridge必须按官方 `Filter.Header/Separator/Select/Text/CheckBox/TriState/Group/Sort` 基类继承关系识别插件自定义子类，并保留 Group层次与 Text/Sort状态；用户修改以类型化 filter-state override进入 search request。筛选是否激活是独立 Presentation/request mode：空 override表示使用插件默认 `FilterList` 状态而非“未筛选”，激活后分类栏焦点属于“筛选”且请求不继承 latest/popular section；Catalog cache identity与runtime payload必须显式区分 filter mode和普通 section mode；external browse的 typed factory、wire validator与 adapter payload必须共享同一字段契约，schema v1新增 `useFilters` 可缺省兼容但未知字段仍拒绝。Filter不得伪装为 `SourceBrowseSection`，浮动搜索只拥有 query与搜索历史。browse projection revision 只属于 metadata，不能作为整页 artwork reload token；source card 的 Sliver child owner 使用 canonical comic identity，raw locator变化不得重置封面 State。固定大小的 catalog page 仍使用显式上一页/下一页，pager 位于内容滚动尾部。列表由 catalog response cache先行投影，但 cache只能服务**当前精确 UI 请求**，不得用“最近 projection”改写 section/query/filter默认状态；source切换时 projection owner先原子切换到目标 source，旧 source内容没有展示资格。后台 refresh只有在稳定字段发生变化时才更新 Presentation；边缘下拉达到刷新阈值后强制绕过缓存请求来源，但保留当前内容直到新数据到达。Mihon 插件的已安装与仓库列表仍按规范化语言分类。

详情页与漫画源页的统一刷新由 `AppPullToRefresh` 拥有 edge trigger、72 px位移、进行中状态与成功/失败结果图标；页面不得叠加第二套刷新状态。

详情扩展数据由 source adapter 负责：`ComicManifest` 可携带首批预览缩略图和评论，
`ComicPreviewSource`/`ComicCommentSource` 只在来源声明能力时提供继续分页。App 只消费
规范化 URI、评论字段和不透明的 `sourceSubId`/回复 ID；图片仍走统一 artwork cache，
评论完整列表和回复通过详情次级页加载，不把评论请求或插件 transport 变成章节目录的
全局门控。Venera 直接复用 `comic.loadThumbnails` 与 `comic.loadComments`，因此已有
`ComicDetails` 能力的来源可渐进显示预览、评论和回复。预览 URI 保留 Venera 的
`@x/y` 裁剪标识用于预览项/widget/painter 的单项身份，但 `onThumbnailLoad` 请求回调接收
去掉裁剪标识的原图地址；该 base URI 也是编码字节缓存身份，App 解码后只绘制对应裁剪区域。
预览栏折叠与展开共用同一套顺序布局。实际行含横图时最多 2 张，纯竖图行最多 3 张；只允许在相邻三个候选内做最小局部重排。完整行直接用全部媒体宽度反算等面积 tile，不再把剩余宽度变成外边距或巨大项间距；标题保留普通内容边距，但图片区不叠加 Card 或水平 border/padding。只有稀疏末行允许相对完整行放大，面积上限为参考完整行的 2.4 倍。阅读设置提供每行最大数量 1–8，默认 4。折叠态只显示同一布局第一行，高度取第一行实际高度；展开态继续消费来源分页，并由 `PageView` 左右分页呈现后续行。展开图片区域按屏幕高度 90% 封顶，开关位于中间且只显示上下箭头。行规划优先使用 `ComicPreviewAsset.width/height`，缺失时以解码后的可见裁剪尺寸回填；缩略图使用 `BoxFit.contain`，不拉伸或强制裁切。预览失败只显示按资源 identity 生成的柔和单色占位，不显示破损图片图标。

App-owned modal panel 的操作行由 `AppDialogActions` 统一投影：关闭固定为左下角 X，确认、
保存或删除位于右侧，不再使用“取消”文字按钮。

### 插件与平台桥

- `plugin_host`：信任、权限、请求计划、身份适配和插件生命周期。
- `plugin_host_bridge`：Android 隔离进程与 Mihon/Venera runtime 适配。Mihon 设备发现只覆盖作为系统共享 APK安装的扩展，合并 `getInstalledPackages`、`getInstalledApplications` 与已知仓库 package name的精确 `getPackageInfo`；每个候选的 manifest、metadata、签名、ABI与 entry失败必须返回诊断，不得静默丢弃。Mihon App私有 `filesDir` 中的扩展不能跨 App读取，必须从 ZIC 仓库独立安装。APK 候选按扩展 feature 或标准 package prefix识别；entry/ABI meta-data随后从 manifest原值或字符串资源解析，多个 entry class可用逗号、分号或换行分隔。隔离 runtime 的公共网络 ABI只要求 `AndroidCookieJar` 等稳定适配器，`AndroidBrowserCookieSession` 属于 network bridge内部实现，不得被 plugin host直接 import或列入 common runtime必需类。动态 ABI按原始类名加载 `dev.zic.network.*` common 类型；所有列入完整性预检的网络类型必须由 `network_bridge` consumer R8规则显式保留类名和成员，不能依赖普通源码引用阻止 Release混淆。
- `network_bridge`：浏览器、Cookie/localStorage 快照、challenge 恢复和共享网络能力。
- `bridge`：Dart FFI、native source/cursor/frame ABI 和两个进程常驻 decode isolate。
- `texture_bridge`：Android texture lease、SurfaceProducer、单 lane RGBA blit、schedule 和 release。
- `apps/app`：composition、导航和产品页面；不得定义资源算法。

## 4. Reader 数据流

```text
Reader interaction / viewport / presentation size
  -> ReaderObs
  -> RoleResolver + HeuristicPolicy
  -> DemandPlan diff
  -> PipelineReaderSession / LiveCoordinator
  -> DownloadSession -> DecodeSession -> UploadSession
  -> PipelinePageStream
  -> reader_runtime / Reader presentation
```

Reader 可以提交 stable page、fractional position、目标页覆盖率、阅读方向、viewport/physical target、interaction/zoom，以及 pause/resume/speed/jump 等命令。

Reader 只能消费不可变页面状态、进度、错误和 `PipelinePageSurface`。它不得接触 mutable session、transport、artifact store、scheduler、cursor/frame handle 或 texture registry。
`reader_runtime` 在页码/阅读模式改变时通过既有 progress facade 提交最新 checkpoint。SQLite 实现
使用独立 progress isolate/WAL connection；Reader 热路径只将 checkpoint 有序入队，不执行同步
sqlite3、章节 JSON 解码或 `HomeLibrarySession` 发布。每个 Reader route 只在 composition 内持有自己的
latest progress；route 返回后只把该最终 progress 发布到 `HomeLibrarySession` 一次，不等待 durable
barrier，也不 reload library/history。磁盘完成不得成为翻页或退出动画的前置条件。
`HomeLibrarySession` 同时记录 library projection revision；reload 在开始阶段捕获的 entries/SavedComic snapshot如果在 enrichment期间已被 write-through mutation超越，结束时不得覆盖更新后的 mounted projection，download snapshot也必须基于最终可见 entries。
inactive/paused/detached 继续主动入队最终 checkpoint，进程被系统直接终止只提供 best effort。

## 5. 页面角色、窗口与优先级

`RoleResolver` 使用以下角色：

- `current`：stable page；
- `last`：仅用于 upload/output retention 的叠加标记，不占用相对页窗口；刚离开 current 的相邻页仍按 `previous/next` 参与 download/decode；
- `transition`：拖动目标页；横向覆盖率达到 0.15，纵向只要真实进入视口即建立；
- `next`、`next2`、`previous`：深度预解码角色；
- `near`、`far`：只保留 encoded download 的邻页；
- `detached`：窗口外。

稳定 encoded window 为前 7、后 3。深度 decode 角色窗口为前 2、后 1；更远页面仍可下载，但不获得动画深水位。

network 的 `NetLane` 与 decode/upload lane 都由 composition-owned scheduler 负责；current 的前台执行身份必须贯穿三条 lane：

- normal concurrency 仍为 network 5、decode 3、upload 2；network local bucket 2、remote source bucket 5；
- current priority 1000；network/decode/upload 各保留 1 个仅 current 可用的高优先级 handoff slot，transition priority 900 不占该保留槽；
- network `NetLane`以normal=5、current-only reserved=1为单一物理调度边界：normal priority 780/800/820/900只参与排队与active rank迁移，不得为了normal-slot pressure主动取消receiving task；current=1000在5个normal槽已满时先直接借第6个reserved槽，不得把“借handoff”本身实现为先cancel victim。只有normal+reserved均真实饱和且current持续blocked时，才允许统一`NetPolicyRank`按40分margin选择victim；破坏性preemption还必须满足NetLane-owned incoming candidate stability，Reader当前为100ms，free/reserved admission不受该等待影响。每个NetLane同一时刻最多一个preemption victim处于已cancel但未物理退出状态，其他blocked current继续排队/更新rank，victim真实退出后再pump，禁止一个scrub burst并行扩大取消面。logical claim归零的already-admitted task仍迁移rank0并标记`demanded=false`，queued未admit可直接移除；normal slot不足时只允许回收这种inactive active task，仍`demanded=true`的窗口成员不受normal reclaim。consumer-bound transport真实dispose/错误/显式用户终止仍是独立硬取消边界。Venera单JavaScript request-plan permit继续独立使用controlled floor=780与current动态preemption，因为它保护的是单context invocation而非最终图片HTTP槽；旧JavaScript必须真实`finished(requestId)`后才能转交permit。
- DownloadJob 不读取 holder depth、播放状态或页面控件；远端下载窗口、decode/upload execution reservation 与播放水位分别由唯一 owner 管理。

## 6. Decode 水位与 Transition 首帧

动态页面的 role 最大 holder 深度为：

```text
current / logical next / next2 / previous = 7 / 5 / 3 / 2
```

current 的浅水位 bootstrap 优先于 speculative neighbor：动态 current depth < 3 时，next/next2/previous 的实际 refill 目标暂为 0；静态 current 只需 1 帧。

```text
current depth < min(3, role max) -> current bootstrap；current 等 source 时，真实 viewport transition 可执行 `t>0` 独立取得 1 帧
```

bootstrap 完成后恢复 staged refill：

```text
n>1, m>1, p>1, c>4, n>2, c>6, n>3, m>2, n>4（current bootstrap 已覆盖 c>2）
```

阈值仍是严格水位，实际 batch 可自然越过。current/source 尚未建立浅水位时不得让 speculative neighbor 绕行 refill；真实 transition 只在 current 暂时无 source 资格时可取一帧，防止拖动目标黑屏。

静态页一帧即满足，但静态证据只能降低**既有 decode 前2/后1窗口**内页面的成本，不能把 encoded 7/3 的 near/far 扩大成 decode/upload 窗口；真实进入 viewport 的纵向静态页可作为可见输出例外，回收仍由 `FrameBudgeter` 权威执行。encoded previous3/next7同时是逻辑/retention与DownloadDemand窗口，动画不得再缩成2/4。动画/未决WebP只附加task-local response-body frame credit：current/可见transition无限流，next/next2/previous为5/3/2，其余远端先1，既有decode水位只把对应外层credit升到2。`WebpFramePrefixTracker.completedFrames`仅是ANMF encoded结构进度；DecodeSession唯一产出playable-prefix evidence并generation-aware投影到DownloadSession。正target只有structural count与decoder playable-prefix floor同时满足才可park。dev.268起，park不再结束transport attempt：`DownloadJob` flush authoritative pending bytes后保留同一ByteResponse/StreamIterator，调用NetLane释放body-read permit；`active`只计持permit任务，`running/parkedResponses`独立记录live response。demand/target/floor变化后同一task重新竞争permit并原地继续，Range capability只影响真实eviction后的resume方式，不再决定水位满足时是否主动关闭response。Reader stable parked-response上限10；超限才以typed `parked-response-eviction`真实销毁response。`consumerPacing`不承诺native upstream完全停收，因此parking必须有界；不得恢复每100ms pseudo drain、`DownloadFlowSuspended`、`retainFlowResponse`或normal `inactive-reclaim`。physical frame proof由DownloadSession generation owner保存，target0/current始终表示网络需要继续。sealed source expected-length幂等、artifact-cache/resident bypass、normal body-read5+current-reserved1保持不变；这里的5+1是read permit，不是live socket/response上限。

## 7. 下载、partial 与 source ingress

普通 response 进入 `DownloadJob` 后先合并 transport 的任意小块：首批约 16 KiB，后续按 64 KiB source-progress quantum 提交到 `DownloadSession`。这与 WebP decode-prefix hint 是两个独立概念：

- local/content/file/asset prefix quantum：1 MiB；
- remote prefix quantum：256 KiB。

`DownloadSession` 保证连续前缀、单 writer、validator/range、seal 和 promotion。网络 attempt 生命周期与 playback artifact authority 分离：已有 committed partial 在 transport restart、无 validator 或 Range 拒绝时保持原文件、epoch 与匹配的内存 Ingress。strong validator 仍优先直接 Range resume；无 validator但已有可信 total length 时，`DownloadJob`先请求最多64 KiB的尾部 overlap Range，只有精确206、精确range start、total length与旧记录一致且 overlap逐字节一致时，才从旧 committed boundary继续单调 append。服务器忽略 Range而返回200时必须复用同一个response进入完整前缀CRC catch-up，不得为了fallback再打开第二条full response；probe不适用时才直接从 byte 0 catch-up。full-body continuation采用两级成本admission：partial<1MiB不限制；1–8MiB只有动态TaskControl priority>=820才继续；partial>=8MiB只有visible transition/current的priority>=900才继续。 已经通过admission并开始消费不可恢复full-body response后，DownloadJob只向NetLane-owned CancelToken报告attempt已投入wall time与response已消费bytes；NetLane在active victim selection中把时间成本按5s尺度、流量成本按4MiB尺度映射为同一连续`costScore`；同时计算bounded +100投影与base→current-safe headroom投影，当前取两者间`1/3 bounded + 2/3 headroom`固定插值。该retention只影响“取消谁”，不改变pending/admission priority；logical detach后成本仍有经济意义，但不能单独占满全部安全headroom。priority1000 current始终保留既有40点preemption margin。被defer的DownloadId以当前committedLength作为composition `DownloadTransferOwner`内存记忆，低优先级demand detach/re-add不得在partial未增长时重新probe；length变化或priority达到对应门槛时必须清除defer并重新probe，因此该状态不是持久endpoint能力。Range probe本身仍允许；admission不得读取endpoint hash、`duplicatePrefixBytes`、decode/playback状态形成policy。所有重复校验字节只用于 continuity proof，不写 artifact/Ingress；不一致、catch-up未完成即取消或失败只终止当前 network attempt，不使旧 playable prefix倒退。scheduler/consumer typed `ErrorCode.cancelled`只表示attempt lifecycle结束：DownloadJob必须flush已到达bytes并pause writer，`DownloadSession`保持`idle/failure=null`与原committedLength；`DownloadState.failed`只允许表达真实network/content/validator/artifact failure，NetLane preemption不得污染partial validity。只有明确 DownloadId/owner 不匹配、artifact corruption、显式 evict/清缓存才允许减少 committed playback bytes。`restore()` 在现有 Ingress 的 epoch/length/kind/sealed 与 artifact 已一致时不得重建 encoded source。已 receiving 且仍有 demand 的传输不会因 observation revision 机械重建；current priority 变化在同一 lane/session 上迁移。

未 promoted partial 与 source/network task 的热 owner 是downloads层应用级 `CompositionDownloadTransferRuntime`中的 `DownloadRegistry/DownloadTransferOwner/DownloadSession/Artifact`，不是Reader route、chapter command或`ArtifactCacheManager`。生产 App 由`PersistentDownloadComposition`统一拥有该runtime、唯一`PersistentDownloadArtifactStore`与`ArtifactCacheManager`生命周期；Reader current/prefetch和显式chapter command仅attach scoped `TransferDemand`，whole-comic只聚合chapter command。同一exact `DownloadId`跨这些consumer共享单session/writer/request；cancel只移除自己的claim，effective priority取聚合最高值。claim的completion intent与priority正交：Reader机会性prefetch可受costly full-body catch-up门槛约束，显式离线命令即使priority较低仍要求最终完成。logical claim消失只影响调度，不触发durable I/O；hot partial继续属于composition runtime。composition owner必须对idle physical registry执行有界retention：promoted immutable先等待既有`ArtifactCacheManager` ordinary handoff收敛后退休hot session；unfinished prefix仅在hot partial预算受压或runtime最终dispose时经`PartialDownloadHandoff`移交cold store，写入失败必须保留hot owner，sessions层不得知道durable store或retention budget。自动promotion handoff对同一immutable session成功一次后不得因后续snapshot/demand churn重复探测backend；显式required exact barrier仍必须重新确认目标durable。store内部用于materialize已完成immutable bytes的session/job不是source/network owner。跨版本共享writer只允许acquire-time verified physical alias：新exact identity尚无session且direct verified equivalence指向一个或多个可复用既有physical session时，resolver只择优join其中一个；两个已存在session不merge，multi-owner proof不得再派生第三owner，source-resident非cache body不join。 physical session创建权只属于transfer acquire/reconcile owner；Pipeline/Reader的presentation/read-only projection（PageStream、progress、fallback bytes与startup readiness）只能做non-creating lookup，必须等demand reconcile完成verified alias后再观察resolved owner，禁止`get(exact)`抢先制造session。claim保留exact URI作为source provider，physical session仅保留首个exact ID作为hot artifact anchor；transport选择与真正的full/range/resume `open()`都必须使用当前provider exact URI，绝不能把physical anchor URI传入另一个版本consumer的transport。committed prefix仍属于physical session的共享resume authority，但ETag/Last-Modified属于产生它们的provider exact request URI：physical alias切换provider时不得把旧URI validator带到新URI，只有`resumeValidatorsFor(actualRequestUri)`命中同一URI才能发strong Range；scope不匹配时保留partial并走既有validatorless overlap continuity proof。显式离线完成仍materialize自己的exact durable ID。dev.228起已删除最后的late verified-equivalent promotion observer/takeover；verified relation不得在artifact commit后异步改变已经存在的physical owner，只有新的demand acquire可建立physical alias。physical→durable partial/artifact persistence属于正常durable边界，不得因历史trace名含`session-handoff`而删除。dev.229起cross-version cold partial不再由版本warmup复制到目标exact key；physical session prepare先恢复exact partial，exact miss才通过ArtifactCacheManager的direct verified equivalence查询durable inactive candidates并直接恢复最长prefix，跨版本validator必须清空，后续continuity仍由DownloadJob overlap proof裁决。durable lookup保持在async prepare边界，不得进入同步Reader demand planning。Animated WebP holder与约30帧水位仍仅属于DecodeSession/playback，不得决定transfer/cache ownership。 对已识别WebP，unsealed source且尚无成功frame时的native decode exception可沿既有prefix hint/source revision wake作为provisional prefix failure等待增长；source sealed或已有成功frame后的decode exception仍是authoritative failure。 dev.230起artifact cache彻底删除directed hard alias/rekey：explicit migration也只登记symmetric verified equivalence；ordinary Reader promotion若已存在同长度direct equivalent durable artifact则不复制第二份exact body，只有required durable command barrier才materialize exact identity。 dev.231起required durable target由physical owner当前claim语义决定：若physical A正服务required exact B，promotion handoff直接把A的hot/resident bytes持久化为B，不先materialize A；只有无required target的ordinary promotion才以physical session.id作为默认durable target。 dev.236起Reader current transfer progress同样只投影demand reconcile后resolved physical `DownloadSession.snapshot`：Pipeline不得维护logical exact-id→session第二映射，Reader只消费只读notifier；Reader-local ingress诊断scope使用physical session lifecycle ID。 active source provider属于physical task lease：logical claim lifetime、transport lifetime与request/provider选择彼此分离。task可通过通用`retainedTransportFor(uri)`取得独立于consumer close边界的transport capability；consumer-bound transport在真实dispose时仍必须cancel并等待物理退出，task-retained transport可继续同一physical writer/partial。provider exact一旦随physical network task admit即成为该task lifetime事实；verified-equivalent logical exact/current/rank变化只能迁移同一NetLane task priority，不得为了切URI取消并重开provider。只有attempt完成/失败或consumer-bound transport真实dispose才结束该request authority，后续task再从当时preferred claim选provider。NetLane policy rank只决定physical task slot/preemption并独占restart-cost retention；costly full-body catch-up仍由`TransferRankPolicy`把preserved-prefix成本映射为cost rank后与demand rank比较。`DownloadSession`另拥有transient transport cursor（attempt sequence/active/absolute network cursor），由`DownloadJob`随实际response字节推进；它可在Range→200重读时落后于monotonic committed partial，但绝不参与resume、identity、durable或rank。Pipeline/Reader只读投影两者：authoritative/max partial保持直线，当前transport以VibeVenera speed-color语义的波浪线显示，从而直接区分prefix replay、attempt reset与真实partial增长。sessions不得知道Reader role、1000、Venera/Mihon/source类型，也不得建立第二scheduler/transport registry。

完整 local immutable 或 durable cache response可标记 resident，并经权威 session/source ingress；错误、取消、range response 或长度不一致不得写入完整热字节。

Home/书架封面上的下载完成标记只表示**显式下载命令完成后的临时反馈**，不表示 durable cache residency。单章节命令和整本队列命令必须区分；整本标记只能由 `WholeComicQueuePhase.complete` 产生，任意一个 `ChapterDownloadSnapshot.isComplete` 无权推导整本完成。该反馈属于 Home Presentation、以 canonical comic identity关联，并在用户进入该漫画详情时消费；真实离线状态仍由 downloads/artifact owner维护。

## 8. Animated WebP 生产与播放

```text
transport / artifact stream
  -> DownloadSession ingress
  -> native growing source
  -> demux metadata / NativeCursor
  -> process-lifetime Dart decode isolate
  -> libwebp single-thread frame decode
  -> premultiplied target-canvas RGBA
  -> FrameHolder
  -> UploadSession
  -> Android texture 或 Flutter fallback
```

稳定约束：
- opaque plugin URI不能让transport-cost policy等待完整animation metadata：physical/Reader ingress实际sniff到`ContentKind.webp`后，只投影runtime WebP cost evidence以启用既有bounded 5/3/2/1 body flow；该evidence不等于`animated=true`，DecodeSession的authoritative static/animated classification始终优先并可撤销cost-only推断；
- 两个 decode isolate 在进程期常驻；libwebp 帧内单线程；
- 首次 native 请求优先单帧，current 后续请求最多批量返回两帧；
- holder 是 decoded frame 的权威缓冲；可见 output 不计作 successor；
- 缺少 successor 时保持当前 output，等待 producer 通知，不进入 startup-buffer，也不阻塞其他页面 decode；
- playback 使用最近 deadline 的 one-shot wake；静态零时长帧不启动 timer；
- finite animation 到 EOF 保留最后一帧；
- metadata 未完成且 source 增长时允许刷新 demux；未封缄 `needMoreData` 等待 source revision，不用定时销毁 cursor；source revision 是 Reader-local projection 的状态事实，只有实际 decode fill 或 DecodeSession 已证明无需 fill 后才能记为 consumed，current-bootstrap 暂时门控邻页不得吞掉其 pending source wake； `SourceEpoch`的decode authority只属于Reader-local ingress projection，不得再由DecodeSession同时读取physical DownloadSession epoch形成第二generation owner；projection在同epoch内rebuild并替换`EncodedSource`实例时，DecodeSession必须释放旧cursor/holder并重新绑定当前source，异步decode期间projection epoch变化属于生命周期cancel而非内容failure，cursor复用必须同时满足projection epoch与source实例identity一致；
- target canvas 使用 contain 和 `height / width`，不裁切、不使用负位移或页面重叠掩盖接缝。

## 9. Upload 与 Android texture

primary upload 角色为 current、transition；上一 current 的 output retention通过独立 `retainedIndex`叠加 `last` upload demand，不改变该页的相对 previous/next 网络与解码角色。远离7/3窗口时 retention只保 output，不产生 download/decode。推测静态邻页可在预算内预上传。

Android 路径使用默认 platform MethodChannel、一个串行 blit lane和普通 `mainHandler.post`：

1. retain native frame；
2. 单 lane 复制预乘 RGBA；
3. platform thread 调用 `SurfaceProducer.scheduleFrame()`；
4. 原子替换 output retained frame；
5. 返回 MethodChannel；
6. UploadSession 记录 presentation 并推进 deadline。

已承载页面 output 的 texture lease 在 output 结束时真实释放，不回到 Reader 间复用池。只有从未呈现过的预热 lease 可短期复用，App 非 resumed 时清理 idle prewarm。platform queue、schedule queue/call、blit 和 channel dispatch 必须分别计时。

## 10. Reader 资源会话 retention

Reader Host 从 `PipelineReaderSessionFactory.acquire` 获取资源会话并在退出时 `release`。退出 Reader 不等于立即驱逐整章资源：

- retention pool 最多保留 1 个 idle 章节会话；TTL 为 2 分钟；
- key 包含稳定章节/source revision、loader URI/revision 和 composition 能力指纹；临时 loader 对象 identity 不参与；
- 保留Reader-local SourcePool、Decode/Upload/media runtime以及对composition transfer runtime的consumer lease；physical DownloadRegistry、artifact/partial handoff与transfer workspace独立于Reader会话生命周期；
- 释放 Reader binding、page projection、playback wake、present claim 和 used texture；
- 不同 key、TTL 到期、容量淘汰或 composition shutdown 时才完整逆序 dispose。

这是一条资源 lease，不是 Reader UI 缓存，也不允许跨 Reader 复用 used SurfaceProducer。

来源页打开已经持久化为 `LibraryComic` 的同一漫画时，source route lock 是该导航的唯一 presentation lock；不得在持有同一 `sourceId + raw comicId` lock 时再次调用会重复申请该 lock 的入口。路由锁只存在于内存导航生命周期，不写入 library，也不参与持久 identity。

## 10.1 Reader progress 与阅读历史

Reader 页面变化产生的 `ReadingProgress` 由 `reader_runtime` 串行合并后写入 App 提供的 progress facade。同一 Reader 同时只有一个 active writer；较新的 pending progress覆盖尚未开始写入的旧值，禁止并行 Future 倒序完成后覆盖新页码。

正常导航返回不等待 SQLite pending/active writer 清空；Reader callback只 enqueue checkpoint，composition route-local `latestProgress` 在 pop 后立即替换 Home/详情内存投影一次，因此阅读历史不依赖再次进入详情或整库 reload。`inactive`、`paused`、`detached` 和每次稳定页面变化继续 best-effort checkpoint，以降低进程意外终止的损失窗口；操作系统强杀无法提供绝对完成保证，文档和 UI不得声称 crash-safe commit。

## 11. Identity、缓存与 artifact

不同 identity 层不可混用：catalog identity 定位实体；DownloadId 表示确定字节版本；DecodeId 还包含 epoch、target 和 renderer；presentation identity 只表示页面位置/输出。

缓存分为两个权威平面：

- `ResourceCacheCoordinator.responses`：封面、搜索、详情和章节元数据，使用稳定 namespace/identity/revision、weight、TTL 和 in-flight join；external artwork 使用 source-confirmed canonical comic identity + role，raw runtime locator 不参与 durable artwork 分区；
- `ArtifactCacheManager`：Reader 不可变页面 artifact，默认热字节 10 项/256 MiB、alias 上限 8192，并连接持久 backend。

封面 URL/token 不是稳定 comic identity；verified checksum、来源 page key、内容 hash 或用户确认迁移才可登记 artifact equivalence。App/Reader 不得创建私有图片字节 LRU，也不得让 cache hit 共享 cursor、timer 或 decode identity。

### 11.1 当前生产代码的 key/id 对照

以下是现有实现中容易被混称为“key”的几组身份。它们的用途不同，不能用标题、显示名或
图片 URL 互相替代。

| 名称 | 所有者/含义 | 当前组成和用途 |
| --- | --- | --- |
| `sourceId` | 来源身份 | 插件/来源的稳定 ID，不是来源显示名；参与 source namespace、漫画 namespace、`ContentId` 和资源请求绑定。 |
| raw `comicId` | 来源原生 runtime locator | `Comic`、`SavedComicRecord`、`LibraryComic` 与章节归属保留的原始漫画定位值。Mihon 可把可变 SManga 快照编码进该值，因此它只保证“如何再次调用插件”，不得假定为 durable artwork identity。 |
| `LibraryComic.identity` / Flutter comic key | 书架实体身份 | 当前为 `sourceId\u0000comicId`（UI key 再加各自前缀）；标题、作者和封面 URL 都不参与。两个同名漫画只有在这组身份也相同才会被视为同一个实体。 |
| `canonicalComicId` | 来源确认的稳定同源身份 | 由来源从 raw locator 投影的稳定等价值，用于冷书架归并和 durable comic/artwork namespace；不得替换插件请求、章节或 Reader `ContentId` 中的 raw `comicId`。Mihon 当前以规范化漫画 Web URL投影 canonical identity。 |
| `chapterId` | 来源原生章节身份 | `Chapter`/`ChapterManifest` 的章节身份；章节元数据响应 key 使用 `[sourceId, chapterId]`，并挂到已知漫画 namespace。 |
| `pageId` / `PageAsset.assetKey` | 章节内页面身份 | `PageAsset` 保留 `pageId` 和 `chapterId`，`assetKey` 为 `chapterId/pageId`；它不是封面/预览响应缓存 key。 |
| `ContentId` | Reader 内容实体身份 | `[sourceId, comicId, chapterId, pageId]`，用于确定一个漫画章节页面；`ContentId.key` 只服务 Reader/download identity。 |
| `DownloadId` | 确定字节版本 | `ContentId + sourceRevision + canonicalUri`，用于 Reader 下载/artifact；页面 URL 变化或来源版本变化会形成新的确定字节身份。 |
| `DecodeId` | 解码输出身份 | `DownloadId + physicalWidth + physicalHeight + pixelFormat + renderer`；不参与首页/详情的图片响应缓存。 |
| `ResourceCacheKey` | 响应缓存实体身份 | 四元组 `kind + identity + namespace + revision`；四项都参与 equality/hash。图片使用 `kind=imageBytes`，详情/章节/搜索分别使用对应 response kind。 |
| `coverUri` / `coverSourceId` | 图片 locator | 只告诉 artwork gateway 去哪里取图；可能是 HTTP(S)、`mihon:resource:` 或本地 locator，本身不参与稳定漫画身份。外部封面响应使用 `[sourceId, canonicalComicId, role=cover]`，URL变化不会分裂 namespace。 |
| `previewUri` | 预览项 locator 和绘制身份 | 详情预览完整 URI（包括 Venera `@x/y` 裁剪后缀）保留在预览项、widget 和 painter 中；编码字节缓存及实际请求使用去掉 `@x/y` 的 base URI。 |
| `resourceRole` | 漫画图片角色 | 封面为 `cover`；详情预览为 `preview:<base previewUri>`；其他带 URI 的 artwork 角色同样使用 base URI。外部 artwork 响应 key 使用 source + canonical comic identity + role；raw comic ID 只传给 runtime loader。 |

### 11.2 同源版本与迁移身份

同源版本必须区分以下身份，任何一层都不得用标题或 URL 字符串替代：

- **raw locator identity**：`sourceId + raw comicId`，是插件请求、SavedComic、章节归属和迁移前后实体的真实定位身份；同一来源的新旧版本必须保留不同 raw comicId。
- **canonical comparison identity**：来源确认的同源等价比较值，只用于归并重复投影和比较候选；它不能替换 raw locator，也不能直接改写章节、页面或下载 key。
- **version relation identity**：`sourceId + predecessorComicId + successorComicId`。关系必须由 `ComicVersionSource` 或已持久化的来源确认结果产生；标题搜索结果不能自动成为版本关系。
- **chapter/page identity**：章节始终为 `sourceId + chapterId`，Reader 页面为 `sourceId + comicId + chapterId + pageId`。迁移时只有章节原生 identity 精确匹配才复制阅读进度和已读状态；**sequence-only** 匹配仅显示在比较报告中，不复制状态。
- **presentation identity**：Flutter key、详情提示和 Reader 一次性提醒只能引用上述稳定复合身份；Widget key、当前章节、封面 URL、按钮状态和 runtime adapter 对象都不是持久身份。

同源 successor 发现后写入 `ComicVersionRelationStore`；`HomeLibrarySession` 在 enrichment 时一次加载全部 relation，并在新 relation 写入时同步更新内存投影，因此 Home/source browser 无需依赖详情页副作用即可判断旧版更新。source-card `!`按relation predecessor/successor的raw+canonical identity区分，不能因library alias归并吞掉predecessor或在successor误报。详情页multiple versions先选择；详情/Reader入口异步检查版本并以source request-plan强identity验证page offset，mapping持久化后Reader只本地恢复verified equivalence；cross-version cold partial只在physical prepare exact miss时从direct equivalents恢复并清空validator，继续由DownloadJob overlap probe验证真实续传。确认迁移后只复制library实体状态；媒体artifact不做hard alias/rekey。

稳定响应 key 的编码由 `encodeStableCacheKey` 负责：使用 `zic-key-v1:` 前缀和长度前缀组件，
因此 URL 中的 `/`、`:`、`@` 等字符不会造成分隔符碰撞。当前图片 key 的实际关系如下：

```text
sourceId + canonical comic identity
  -> durable comic/artwork namespace
  -> imageBytes / comic-response(role) / revision

raw comicId
  -> plugin runtime locator / chapter ownership / Reader identity only

封面:
  [sourceId, canonicalComicId, role=cover, revision=artwork-v2]

详情预览:
  [sourceId, canonicalComicId, role=preview:<base previewUri>, revision=artwork-v2]
  完整 previewUri -> cache/request 使用去掉 @x/y 的 base URI
                    -> App widget/painter 仍按完整 URI 的 @x/y 裁剪

持久化文件:
  hash(kind + identity + namespace + revision)
  + 文件记录再次校验完整 ResourceCacheKey
```

首页/详情 artwork 的缓存层顺序是 memory -> durable byte store -> source loader。durable命中先读取为
由 presentation 持有的 `Uint8List`，不会把 cache-managed文件路径交给 `FileImage`。持久 artwork 的
**身份**与**保留生命周期**是两个维度：来源 browse/preview 等临时响应属于 `transient`，可受 TTL/LRU/
maintenance 容量回收；已进入 library/history/details 持久语义的 cover在同一个 `ResourceCacheKey` 上
单调晋升为 `retained`，不参与运行期容量/TTL淘汰，只能由精确 artwork revision失效、漫画资源显式删除
或用户清缓存移除。晋升不能创建第二 namespace。内存 response plane仍保持有界，presentation已取得的 bytes
也不依赖 durable entry继续存在。source-independent warm probe命中时，首页封面不会解析来源或启动插件；
miss才进入 gateway/source transport。
因此预览图的完整 URI 仍决定每个 widget 的裁剪区域，但同一 base URL 的编码字节只保留一份，
避免旧实现按每个 `@x/y` 裁剪重复请求和占用缓存。旧的每裁剪项 role 不会与新的 base role 相同，因此无需迁移预览裁剪缓存。封面 durable
namespace 由 canonical comic identity 固定，raw Mihon `comicId`、封面 URL、详情补全后的 SManga
字段变化都不得创建第二个 namespace。`comicArtworkCacheSchemaRevision` 由 resource cache/gateway
统一拥有；external artwork调用方只能提供可选 content revision，不得再次传入基础 schema revision，
否则会把 browse 与 details/history 分裂成 `artwork-v2` 和 `artwork-v2:artwork-v2` 两套 namespace。
封面内容版本变化由 content revision/精确 artwork refresh处理，不能通过 presentation State、provider eviction
或新的 raw alias 隐式换 key。catalog details/chapter刷新只能失效 metadata；不得因共享 comic namespace
顺带删除 retained artwork。整漫画资源删除是独立的显式生命周期操作。

图片加载失败的边界必须分开：cache hit/miss 只说明编码字节是否存在；source loader 的失效路径、非图片响应、权限/challenge/空响应由 gateway 拒绝；Flutter decode 错误只影响 presentation。单张失败的 Trace 至少记录脱敏 `sourceId/raw comicId/resourceRole/URI`、cache origin 和 transport/decode 错误，不能仅凭占位图判断缓存冲突。

### Reader checkpoint 与历史投影边界
Reader 页面变化只 enqueue 最新 `ReadingProgress`，不得等待 SQLite或逐页发布 Home；storage isolate 对同 source/chapter latest-wins，空闲约 8 秒提交、持续活跃最多约 30 秒提交。显式 `saveProgress()`/store close 可等待内部 durability barrier，但 Reader route API不暴露 barrier。
Reader 返回后 Home只更新该 route最终 progress一次，已挂载详情只替换当前章节；不得在返回路径读取/重建整库。硬进程终止仍为 best-effort，不宣称最后一页绝对持久化。

## 12. 插件与网络边界

网络默认 User-Agent 属于 composition-owned 请求策略。AppPreferences 保存当前 fallback UA，默认使用稳定 Android Chrome UA；`main`/composition 以动态 provider 注入通用 `HttpTransport`、Reader/章节下载 fallback、插件仓库 control-plane 与 shared source host transport。来源 request plan 显式 `User-Agent`、Mihon browser-session UA或 source-owned client策略拥有更高优先级，全球设置不得覆盖这些来源权威。Presentation 不得自行构造 HTTP client。

网络执行只有三类合法 owner：

- **source-owned client**：Mihon/Venera 等来源的 CookieJar/interceptor/auth/DNS/TLS/session 语义；未知 client wrapper、重定向、`Set-Cookie` 或无法无状态平铺的响应必须留在这里执行；
  Venera JavaScript `Network.*` 的 Cookie、manual redirect、`cache-time`、`prevent-parallel`、requestId grouping 与同步 JS contract 仍由 plugin-host source runtime拥有，但 HTTP execution 不再由 Kotlin `HttpURLConnection`/DoH/reflective OkHttp拥有；isolated plugin Dart process 持有 reusable rhttp/reqwest resolver client 与 requestId→CancelToken 映射。最终 media replay继续由主流程的 rhttp direct transport执行。由于两者位于不同进程，不能共享同一物理client/连接池，但必须统一到同一 rhttp client family；Kotlin/WebView不得重新建立第二HTTP connection pool。
- **统一 host transport**：仅重放来源已经解析成无状态 request plan 的单次资源请求。生产 Flutter composition由 `downloads_bridge` 注入可取消的 Rust/rhttp streaming transport并复用client/keep-alive；rangeStart=0 的完整/首段response通过媒体前缀校验后保持raw streaming cadence，合法206且`Content-Range.start > 0`的中段不得再次要求完整图片magic header，应直接保持raw stream/cancellation/diagnostics；不得仅因中段不含文件头而转runtime fallback，也不再建立第二套64/256KiB framing。transport packet边界由 `DownloadJob` 统一聚合为首批约16KiB、后续64KiB source-progress quantum后才进入session/native/artifact；pure `downloads` 的 Dart HttpClient只作为非Flutter/test默认。两者都关闭自动redirect，只有无 Cookie状态变化且直接返回编码媒体时才有资格把字节交给 Pipeline，且平台 transport必须观察同一个 `TaskControl`。rhttp持续传输观测只允许通过`ByteResponseReadDiagnostics`在stream结束/取消时snapshot receive-progress与raw-body cadence；HTTP version和匿名endpoint hash仅用于trace。该seam不得提供pause/resume、bandwidth quota或priority，也不得进入Reader/Pipeline/session policy；
- **control-plane HTTP**：插件仓库索引/APK/JS安装等，不属于漫画 response cache，但仍使用 composition 的默认 UA fallback。

`ResourceCacheManager` 是可重新获取 metadata/artwork response 的唯一缓存 owner。Catalog browse/details只管理 metadata，`CachedBrowsableComicSource` 不提供 artwork loader facade；封面、预览不得直接取得 raw source transport。章节正文/Reader page body 明确由 DownloadSession/artifact/Pipeline 管理，因此通过 `ComicSourceResourceGateway.pageResponseLoaderFor/loadPageBytes` 绕过 response cache。两者必须复用同一 source-resolved response loader；full-byte fallback不得直接调用 `source.loadResource()`。章节下载侧只接受原子 `ChapterResourceAccess`，不得分别更新 byte loader 与 streaming transport。

插件先生成 request plan。GET/HEAD 必须零 body且不得携带实体 headers。Mihon 页面资源必须从 `HttpSource.imageRequest(page)`（或等价 source request）保留准确 URL、method、headers和必要的小型 request body；共享 transport不得注入 Venera专用默认 UA。Android宿主必须提供可执行 source实际返回 HTTP(S)媒体 URL 的统一网络能力，不能按具体插件/域名维护 cleartext白名单或擅自 HTTPS改写；URL选择仍属于 source/request plan。宿主直连前同步投影当前 source OkHttp CookieJar Cookie与同站点 browser-session UA。若宿主 HTTP成功但响应前缀不是支持的编码图片，字节不得进入 Pipeline/decoder，而应使用已有 source-owned runtime network兼容路径；普通可重放图片仍由宿主流式 transport进入统一 Pipeline，完整图片正文不得仅因 Cookie/header需求改走 JSON/Base64 RPC。页面下载的 retry只有 `LiveCoordinator` 一个 owner：runtime transient错误必须投影为 `ErrorCode.network`后进入有界重试；非 retryable/source错误或重试耗尽在当前 demand内成为 terminal，source listener/finally不得自行重复提交。

Cloudflare 可见浏览器的 Cookie 与 User-Agent 必须属于同一个浏览器 session。验证模式下 `NetworkBrowserActivity` 不得把插件/OkHttp 的静态 UA 写入 WebView；WebView 使用当前 Android WebView provider 的真实 UA，并把该 UA 与同站点 Cookie/localStorage 写入同一 snapshot revision。Mihon runtime 读取 snapshot 时不再要求它等于启动前的静态 UA，而是在 OkHttp application interceptor 中对同站点请求逐请求采用 snapshot UA；CookieJar 同步导入同一 revision 的 Cookie。这样避免 `cf_clearance` 来自真实 WebView、HTTP 请求却继续声明另一浏览器/平台所产生的 Cloudflare 指纹不一致。

`sourceVerificationRequired` 只由 host-owned typed `SourceVerificationRequiredException` 产生。`cf-mitigated: challenge` 是明确协议证据；否则 HTTP 状态必须为 403/503、`Server` 必须是 Cloudflare，并且 HTML 必须含 Mihon 同样使用的 `challenge-error-title` 或 `challenge-error-text` 实际交互 challenge DOM。仅出现 `challenge-platform`、`cf-chl-*`、`Just a moment`、Cloudflare Server header或普通 403/503都不足以触发浏览器验证，避免把 geo/access block误分类为可通过 WebView解决的验证码。异常 envelope 同时携带实际失败 request URL、HTTP 状态和请求时 `cf_clearance` 是否存在；这些字段只用于恢复路由和诊断，不进入持久 identity。Mihon 主网络和 ABI兼容 interceptor均委托同一个 detector；不得创建隐藏 WebView、等待 challenge或按异常消息文本猜测。

插件和平台桥不得导航、创建 Reader、提交 demand、直接读写 artifact、访问 App controller，或把 Cookie/token/Base64 payload 原文写入 Trace。

## 13. Telemetry 与关闭

状态所有者产生权威事件；App 只做有界导出。composition physical transfer事件对共享App/export sink只能写一次；每Reader可保留独立memory trace projection，但不得经多个Reader wrapper把同一physical event重复写入同一全局sink。长 identity 使用 hash/长度摘要；导出投影可按稳定语义桶合并高频诊断样本，例如 `framePipelineTiming` 按 trace reason / dominant stage / role，`decodeRefill` 按 role / stage / source-wake 分桶，并保留 first/last、count 与关键 timing/source revision 的 min/max。该合并只属于导出观测，不改变运行时事件或策略；错误、retry、writer rejection、resume/source read、session retain/reuse 和生命周期边缘不得因导出压缩丢失。overlapping total 不得与子阶段重复参与 dominant 归因。 production rhttp 的HTTP version与匿名endpoint hash属于每response低开销观测；高频native receive-progress只允许non-product或显式诊断构建启用，且不得改变transport cadence或成为调度输入。

完整关闭遵循依赖逆序：停止新 demand，关闭 upload/decode/download，释放 frame/output/texture，关闭 runtime scheduler与 workspace，最后由 App 关闭其创建的平台 facade。外部注入 capability 不由消费方关闭。

## 14. 静态门禁

静态门禁阻止明显的依赖反转、API 泄漏、重复权威和文档漂移，但不能替代 `flutter analyze`、Dart/Flutter/Rust tests、Android debug/release build 和真机生命周期/性能验证。
