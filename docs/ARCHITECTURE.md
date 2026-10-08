# zic Architecture
本文件描述当前生产代码的稳定所有权、依赖方向、数据流和生命周期。
## 1. 架构目标
架构目标是以单一所有权、单向依赖、唯一调度权威和可观察生命周期，把 Reader 的只读呈现、Pipeline 资源处理、下载/缓存 authority 与平台能力组合在一起；
实现机制按后续所有权边界说明，产品合同以 `SPEC.md` 和 `DOWNLOAD_STORAGE_SPEC.md` 为准。
## 2. 分层与依赖
- 平台能力由 composition root 原子注入；核心包不反向依赖 Widget、Android plugin 或具体 FFI 实现。
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
领域 identity、值对象和不可变实体。`TaskControl` 是 scheduler-owned work 跨层只读控制合同，只暴露 cancellation 与 priority；
需要保持已admit工作实时rank的下层可选择观察scheduler-owned priority change，但只能重新评估既有执行资格，不能写priority或形成第二调度器；消费层不得借此拥有调度策略。
不得依赖 UI、插件、网络、缓存、数据库或平台桥。
### `catalog`

漫画源、漫画/章节/page manifest、来源能力和 catalog cache identity。
`CachedBrowsableComicSource` 缓存 browse、details、preview/comment 分页和 chapter metadata，
所有这些可重新获取的响应共用注入的 `ResourceCacheManager`，但按稳定 response identity 分开；
完整details响应嵌入请求的raw漫画/章节父ID，因此response key按raw comicId区分；同源别名仍共用canonical namespace失效与artwork身份，不能把一种别名的manifest返回给另一种。
它不拥有 artwork 加载，Reader 页面正文仍透传到统一 Pipeline。

### `resource_cache`

封面、详情、搜索、章节元数据等可重新获取响应的唯一缓存平面，拥有容量、TTL、分类预算、in-flight 合并、持久 byte store 和失效策略。
retained 晋升沿用同一 response key：byte store 返回有效 durable payload 是否存在，已有副本只改生命周期元数据；transient 副本缺失时，manager 将仍未过期的内存响应后台补写为 retained，不重新请求来源。晋升意图由 manager 内部 claim 标识，精确失效、强制刷新和 clear 撤销该 claim；内存容量淘汰不撤销持久化意图。补写沿用原 persistence tail，不阻塞呈现或增加网络调度权威。
Android `local-folder` 导入保持正文 SAF/document-tree identity，不复制整本图册；但 cover 是独立的长期 artwork resource：
根目录签名有效且主名精确为 `cover` 的图片优先作为封面并从 Reader 页序列排除，否则第一页同时承担封面与正文。
App composition 在显式导入/刷新时预先 materialize retained cover：静态格式可由 `local_media_bridge` 生成约512×768的有界 derivative；
GIF/WebP animation candidate 则持久化原始 encoded cover，避免把动画所有权错误降格为 Bitmap 首帧；
同时可以在独立 `cover-placeholder` retained key 上保存小型静态 derivative，Home 仅把它作为 presentation acceleration：
placeholder 命中时先真正画出一帧，再切到独立加载的原始动画；
placeholder miss/失败只后台 lazy materialize，不能成为最终 cover 的等待条件或第二 artwork authority。
`ImportedChapterRecord`/compact Home projection保存 cover media format 与 animation hint，
旧完整记录可由 matching page 补回。
Home/Bookshelf 只消费对应 canonical retained artwork，旧导入记录允许在首次 cache miss 时 lazy materialize。

### `transport`

可取消、可分块的 encoded-byte transport、range、validator 和 response 合同。
Reader page 使用可选 `ControlledTransport` 将 scheduler `TaskControl` 贯穿 cache read-through、
source-plan、open与response body；
任何transparent/read-through wrapper若下层支持controlled capability都必须保持同一control，不能因cache miss降级为普通`open()`。
transport可中止自身请求但不拥有priority policy，也不得在请求真实退出前伪释放lane容量；prefix probe后outer stream取消仍必须abort底层response。
它不拥有artifact、Reader demand或播放状态。
`SelfBoundedOpenTransport`只允许lower transport在指定URI的完整open生命周期已经由自身有限deadline覆盖时声明；
此时DownloadJob可省略generic 6s open watchdog，但仍保持同一TaskControl cancellation与6s body-read inactivity watchdog。
已证明self-bounded的open或已报告该phase handoff的同一open在scheduler取消后仍等待原pending Future与迟到response的discard退出，之后才让NetLane归还容量。
ArtifactCacheTransport转发self-bounded fallback时保持相同退出边界；取消信号不得通过Future.any提前完成外层open。无有限deadline证明的legacy open仍由原generic watchdog与迟到discard收敛。
external source只有runtime source明确暴露resource-operation deadline且最终direct media transport也自有open deadline时才可形成该proof；
当前production Mihon/Venera runtime分别由executor的45s/55s invocation limit约束，
`RhttpSourceResourceDirectTransport`另以15s约束client/header open并在header timeout时取消native request。
显式chapter download的LoaderTransport可直接携带该proof；
Reader的`ArtifactCacheTransport`不得把整个wrapper伪装成self-bounded，因为origin前仍有本地cache lookup/foreground阶段。
Reader现在保持外层generic 6s watchdog覆盖这些本地阶段，只有在本地阶段结束且即将进入已证明self-bounded的origin fallback时，
才通过scheduler-owned `OpenPhaseReportingTaskControl`报告一次phase handoff，
由同一DownloadJob撤掉当前open timer并继续等待同一pending future/CancelToken；
lower层不能设置timeout值、retry、priority或admission，body read仍由原6s inactivity watchdog负责。
`ComicSourceResourceGateway` 的 per-page self-bounded proof 必须与 controlled response loader 作为一个 composition capability 原子传递到 `LoaderTransportSource.selfBoundedOpen`；
App/LocalMedia 只传函数而丢失该 bit 会让 `ArtifactCacheTransport` 无法报告 phase handoff，
从而错误地让 generic 6s timer覆盖 Venera/Mihon 已由 runtime/direct owner 自限时的 source-open 阶段。
generic open watchdog真正超时时，DownloadJob必须只abort当前controlled open attempt的私有control，
而不得cancel真实scheduler `CancelToken`；该attempt control持续透明代理实时priority/priorityChanges与scheduler cancellation，
因此owner仍看到`ErrorCode.network`并可按既有retry继续。
已超时的cache/storage lookup即使稍后物理完成，也必须在attempt-control取消检查处终止，禁止在NetLane task已归还后再跨入origin fallback；
真正scheduler cancellation仍沿原CancelToken下沉。

### `storage`
持久化 imported-library 的 bulk SQL/JSON 解码由 storage-owned 短生命周期只读 worker 执行，SQLite handle 不跨 isolate；
同一worker在返回前初始化每个不可变record的manifest投影，页面URI解析不延迟到Home首次authority构建；连接和发布authority仍由原owner持有。
内存 store 以有限 event-turn 预算让步。
schema 20 的 `artifact_replica(access_locator)` 索引和 `CacheScanner.phaseMicros` 服务于恢复扫描诊断，
sidecar 仅是 DB/live owner 的保留提示，不替代正文/partial 存在性与 authority。

partial artifact、连续前缀、校验、seal、原子 promotion、索引和临时 workspace。
对稳定 DownloadId，已经提交并成为 playback authority 的 partial prefix 单调不减；
网络 attempt 重启、validator 缺失或 Range 被拒绝都不能删除、缩短或重建该 prefix。partial append只写入并推进长度，不在UI isolate逐chunk计算CRC；
seal/restore在isolate rehash后提交权威checksum。partial→final promotion的filesystem rename与内存state切换属于Artifact内部事务，
所有encoded read必须由Artifact按preferred/alternate path直接open同一authoritative file handle，
Reader/sessions不得观察或猜测rename窗口。它不决定页面角色或网络优先级。
Android SAF 的 provider document-id/children-listing 缓存只属于路径解析加速，不是文件存在性authority：
正常 create/delete/rename/replace MUST仅失效实际发生mutation的父目录listing；stale exact locator第一次恢复也只失效目标父目录。
只有父document-id无法解析，或scoped recovery后仍失败并怀疑祖先目录被外部整体替换时，MAY退回整tree cache invalidation。

### `downloads`

composition-owned `ArtifactCacheManager`、artifact transport/read scheduler、
verified-equivalence proof、章节/整本持久下载与来源 transport 组合。页面 session 状态本身由 `sessions` 拥有。
Automatic hot-transfer checkpoint 与显式 download placement 是不同 ownership：
canonical physical 与 exact-fallback unfinished checkpoint 都优先在 downloads-owned App-private Direct staging 保存 mutable recovery state；
全局/来源 SAF 可继续承载 generic/historical partial 兼容，但不得仅因配置存在就成为 Reader/composition automatic checkpoint 的默认根。
显式 chapter download 只有在 promoted artifact 已形成后才由 structured placement/mirror owner 写入 SAF 并 pin exact 记录。
旧 external/SAF partial 收敛到 Direct staging 时，persistent store serializer 必须掌握 prefix/locator proof、
new authority commit 与 cleanup debt，Reader 或 App route 不得自行搬运。canonical SAF physical partial 在 composition local-prepare 命中时直接由同一 serializer 迁入 App-private Direct transfer staging 后再借给 hot DownloadSession；禁止先经 DownloadSession writer 从0重放整段 SAF prefix。迁移前取消保留旧 SAF authority，迁移提交后 subsequent visit 直接 adoption 同一 Direct spool（ADR 0340）。

### `media`

encoded source、cursor、frame、output、renderer 和只读 timing capability。它不选择页面角色或 scheduler 策略。

### `sessions`

`DownloadSession`、`DecodeSession`、`UploadSession`、
registry、claim/lease、frame holder、playback timer、Net/Decode/Upload lane 和 `LiveCoordinator`。它是可变媒体状态的权威所有者。
Presentation 已证明某一 artifact-backed generation 无法语义展示时，`DownloadTransferOwner` 还拥有该 physical id 的恢复事务：
recovery barrier 先冻结新 admission 并 quiesce local preparation/NetLane task，
再由 composition cache owner 失效对应 durable authority；
若该坏 generation 已经形成 promoted ephemeral final，recovery reset 必须显式销毁该 final 后再 restore，
禁止普通 `DownloadSession.reset()` 默认保留 final 的语义把同一坏正文重新恢复成 promoted。
普通 reset 仍默认保留 promoted final，只有 presentation semantic rejection 这类已有正文无效证据的路径可以请求 destructive final reset。
成功进入recovery后，`ArtifactCacheManager` 对被恢复的 logical id 与其当前 resolved physical id 建立 transient fresh-source quarantine：
`PartialDownloadHandoff`在选取canonical physical READY/partial之前也必须检查该状态，
memory、persistent、backend-internal equivalent 与 direct-equivalent fallback同样视为 miss。
quarantine 初始unarmed，只有physical session reset以及旧canonical physical READY/partial routing失效完成后才由composition arm。
普通unpinned cache仍由fresh durable store解除；
若rejected exact是显式pinned/manual binding，cache backend只暴露窄retention fact，
composition保留该exact durable对象、让fresh epoch保持hot-only，
并在automatic handoff处解除quarantine而不重新绑定canonical physical或覆盖exact。
若已有required chapter/whole-comic claim，它仍留在同一个physical session上并继续作为exact durable completion owner，
不受hot-only automatic策略限制。随后才以原claims重启；task retirement不得越过此barrier抢跑。
Reader ingress registry必须同时保持physical object generation与Reader encoded generation边界：
unfinished/failed或pending-late-attach source按DownloadSession object identity换代；
already sealed/sourceReady/no-failure且无pending attachment的same-exact immutable projection可跨transient physical session recreation保留。
旧same-id session teardown必须校验concrete session identity，不能删除replacement entry。
synchronized late join只有Reader-local projection自身追平稳定physical epoch/length/sealed且无failure后才能加入live fan-out；
早期probe已发布且精确追平同代sealed正文时，最终join直接复用该encoded source；不能再次从零rebuild而处置decode已绑定的对象。
replay期间consumer通知可暂时隐藏，但publish必须以replay开始前的projection snapshot作为事务基线与最终状态比较，
不能在prefix/kind/revision已更新后才截取`before`。
Reader source watch把encoded content classification与native source growth同等视为decode evidence：
`unknown→fallback/gif/webp`必须立即wake waiting decode，
尤其fallback/gif不得被`sourceReady=false`或尚未seal的partial prefix阻塞到下一次手势/reconcile。
deferred resident range hydration对同一physical `SourceEpoch`的失败是Reader-local终态：
失败后不得仅因requested length尚未满足就在microtask tail中自递归重放，也不得由role/priority churn重新消费同一失败authority；
只有新的physical epoch可以重新尝试。成功中的hydration若同时收到更大的decoder-owned target，仍可在当前成功attempt结束后只接续一次最新target。
UploadSession dispose是generation retirement barrier：
旧generation即使仍有pending prepare也必须立即退休其uploader slot，old async tail不得延迟release到replacement generation；
普通detach/reset仍可使用既有deferred release。
UploadRegistry拥有UploadSession→DecodeSession concrete-generation binding不变量：
logical DecodeId复用时，registry get/prepare必须先与DecodeRegistry当前session做object-identity校验；
不一致时只能退休旧UploadSession并创建replacement，禁止让UploadSession原地跨代换绑或继续读取retired holder。

### `pipeline`

把 `ReaderObs` 纯计算为角色窗口和 `DemandPlan`。它定义优先级、水位和 keep 集合，但不创建 transport、artifact、cursor 或 texture。

### `pipeline_runtime`

Reader 章节资源会话的唯一组合所有者。它把 demand reconcile 到 download/decode/upload session，
发布 `PipelinePageStream`，管理 frame budget、共享 page download lane、artifact handoff 和短期资源会话 retention。
短期 Reader re-entry retention 的 idle LRU 最多保留最近两个 exact session key、TTL 仍为两分钟；
第三个 key 立即淘汰最旧项。
短期 Reader re-entry retention 只允许保留 download/physical transfer/encoded source authority；
route 退出必须立即撤销 demand 与 presentation claims，由现有 Coordinator 退休 Reader-local 媒体。
idle decode/upload、cursor/canvas、frames 与 ingress/source 立即释放；已取消但仍执行的任务保留具体 cursor/source，
经原 DecodeLane/UploadLane 真实退出回执自动回收，不等待 retention TTL，也不得由 Pipeline 提前 evict。
除真实执行期外，不得为了快速重进让 cursor 的 source `Arc` 钉住可由 transfer/artifact 重放的整页 encoded bytes。
它也接收 Presentation 的语义失败反馈并保存最后一次 page-body authority：artifact-cache body 的展示失败可触发每页每 Reader session 一次自动恢复；
显式重试走同一 composition recovery。cache 等价复用时必须保存实际 `storageId + mutation generation`；
恢复只能条件失效产生失败字节的那一代，旧 failure 若晚于 authority 换代到达只能重载当前 generation，禁止删除或 reset 新 authority；
真实失效成功后本 logical/physical recovery group 必须临时禁用全部cache/equivalent source reuse并销毁已被否定的ephemeral promoted final；
quarantine 只有在 destructive reset 完成后才 armed，且只有 store 开始时已 armed 的 fresh exact durable handoff 可解除，
reset 前启动的旧 handoff 不得解除；禁止从session final或sibling binding回灌同一坏正文；`fallback` classification 本身不授权删除。

### `pipeline_native`

把 native source factory、cursor、frame uploader、output projector 和 prewarmer 作为原子 capability 注入 `pipeline_runtime`。
核心 Pipeline 不直接创建具体 FFI 或 Android texture 实现。

### `reader_runtime` / `reader`

`reader` 提供 observation、导航和通用 Flutter Reader；`reader_runtime` 负责产品交互、尺寸投影和 `ReaderObs` 适配。
二者都不拥有资源 session、缓存或 native handle。页面错误 UI 可以报告 presentation failure 和发出显式“重试”命令，但恢复资格、
cache invalidation、session reset 与 network re-admission 全部留在 Pipeline/composition owner。

### Home 组合与生命周期
- Reader native media/process prewarm 只能是 acceleration hint：
  可以在章节 materialization 同时启动，但章节准备/route readiness MUST NOT await prewarm；
  真实 decode worker/texture capability 在需要时自行 join/retry，并保留错误 authority。
  首帧/首个 output 是否已呈现不得改写 NetLane local/remote bucket、
  artifact/cache authority 或 composition-wide local-read pressure。
Home 的运行时绑定就绪与展示投影就绪是两个边界：`HomeServiceHandoff` 在核心服务到达后自动触发，`HomeLibrarySession.adoptServices()` 先完成权威读取、
绑定替换和旧 owner 退役，再由 `ready`/`services-handoff-complete` 收口投影；Reader 只通过 composition 等待能力绑定，不拥有这条生命周期或网络准入。

bootstrap 与 durable services 之间通过稳定 `HomeServiceHandoff` 原地交接现有 `HomeShell/HomeLibrarySession`；
服务到达不会更换 `MaterialApp`、Home key 或导航状态。`_AppServices` 必须显式持有 `ownsLibraryStore`：
独立打开的 durable library 由 service shell close，复用 bootstrap `LazyImportedLibraryStore.ensureDurable()` 的 SQLite 则继续只由 Lazy owner close；
download-service rebuild/degraded shell 只继承 previous ownership bit，
禁止因为 `libraryStore != null` 重新取得 close ownership，避免 App dispose 中 services/bootstrap 对同一 SQLite 双重 close。
快照已证明 revision 一致时 handoff 只切换服务引用，不再次发布同一更新漫画/阅读历史投影。
空安装可以保持 memory-backed Home 而不预建 SQLite/WAL，但 `HomeServiceHandoff.ensureCoreServices` 是首次显式下载的 durable boundary：
详情页在冲突 probe/placement claim 前等待它，Home 的单章执行与整本 enqueue 也在写入前再次等待并采用 durable library、
chapter composition、artifact cache 和 whole-comic queue；强制打开或 adoption 失败会终止动作，不能回退到内存服务后向 UI 宣布下载完成。
外部插件 loader、storage root 等可选 capability 独立于 core service handoff：
即使安装只有 external-plugin manifest、没有 imported-library/download/queue 文件，
或 core SQLite 因跨版本 schema 等原因打开失败，也保留已解析的 storage root 并补充插件 capability，
不替换 memory-backed library/cache 或创建空 SQLite。
外部插件就绪前，Reader 准备与远程章节加载通过独立 `HomeExternalSourceLifecycle.waitForSource()` 保持等待并响应式采纳逐个激活的插件源，
杜绝空 responseLoaders 导致的非本地协议回退错误；controller loader/adoption、exact-source handoff gate、
`sourceChanges` subscription、projection refresh single-flight 与 activation retry 都由该 lifecycle owner 持有，
直接注入的 deferred controller 在没有 loader 时不会被 generic publish 路径升级成全插件 `ready` barrier。
Home 更新/历史、书架画廊/列表的封面子树消费同一 `sourceProjectionChanges` 窄信号，重新读取 current source availability；
既有 source-failed 封面仅在 unavailable→available 时重建资源 Future，健康和 pending 封面保留原请求与 canonical State。
来源发布不使整个 Home library projection 失效；卡片仍只提交 gateway 请求，不持 runtime/retry/network 状态。
`ComicCoverCard` 的 canonical 封面与按 raw comic/resume chapter 定位的点击层为同级节点；
当前点击 key 和命令可随投影更新，不能以其替换封面的祖先并销毁健康或 pending artwork State。
lifecycle close 必须同步封闭新 refresh/adoption 并 join 并发 close；
已经进入 Home projection callback 的 current refresh 必须完整返回后 close 才完成，
但尚在 optional controller loader/ready 阶段且尚未进入 projection callback 的 work 不属于 teardown barrier。
HomeShell composition teardown 必须先 await lifecycle close，
再进入 `HomeLibrarySession.close()`，避免旧 external refresh 撞上 session `_closing`。
App runtime 的 `_AppServices` 只把 external plugin controller 视为独立于 library/download core generation 的可选 capability：
bootstrap/deferred→durable、download-service rebuild 与 degraded fallback 都必须通过单一 ownership transfer 保持同一 controller identity；
predecessor 清空 controller、尚未启动的 stale loader 委托 successor、
已经启动的 predecessor open 必须继续完成并沿 successor 转交（不得从该 flight 内再次调用 successor ensure，
否则 successor 已 join predecessor ready tail 时会形成等待环），且 successor teardown join 该 ready tail；
禁止等待固定超时后复制指针或让旧 services/new services 双重持有 controller。
转移中的 late open 完成后 current `_AppServices` 还必须把 controller 重新发布到 `HomeServiceHandoff`。
install/edit inspection 产生的 pending payload 属于 `ExternalPluginController` 的 transient ownership：
每一代 pending payload 带 controller-private claim，返回的 preview 只有 claim+path 同时匹配 current pending generation 才能 discard/approve；
旧 preview、手工构造的 unclaimed preview 都不得取得更新一代或任意 payload。same-plugin inspect 的 generation 在请求发起时建立；
后发起者立即 supersede 前代，早代慢下载/慢 inspection 即使晚完成也只能清理自身文件，不能重新发布 pending。
producer 的失败清理也只能删除自己的 pending generation。
normal close 必须 drain 本进程 `_pendingPayloads`，inspect 在 final rename/metadata inspection 后都要重验 controller open 状态；
approved/manifest-owned payload 不在该清理集合。
与之独立，approve/retry/remove 及后台 source-identity activation 属于 controller durable mutation admission：
close 本身必须是 joinable 的单一完成边界（并发调用共享同一个 close Future），
底层 `ExternalPluginRuntimeRegistry.close()` 也必须共享单一 close Future；
registry 对同一 plugin 的 deactivate 必须 single-flight，并作为 destructive fence：
一旦 deactivation 已接纳，后续同 plugin `activate/replace` 必须在读取 existing session 或启动 replacement candidate 前拒绝；
反向次序保持不变——activation/replace 先被接纳时 deactivate 等其完成后关闭当时 current session。
该 fence 只按 pluginId 生效，不得阻塞其它 plugin 的独立 activation；registry close 先 drain 已接纳 deactivate、再快照/关闭剩余 sessions，
不能假设 `ExternalComicPluginSession.close()` 天然幂等或 joinable；
controller close 先封 admission、立即触发 registry shutdown，
再等待已接纳 mutation 与 `_manifestWriteTail` 排空，之后才能完成 pending cleanup/sourceChanges close；
controller mutation gate 以 pluginId 为 key：
同 plugin 的 approve/retry/remove/save、后台 activation 与 Mihon runtime restart 必须按 admission 顺序执行，
因为它们共享 `_installed`、pending payload 与 runtime session identity；
后台 `_activateRecord` 还必须在真正取得该 plugin key 后重验捕获的 `InstalledExternalPlugin` 仍与 `_installed[pluginId]` identity 相同，
旧 startup/source-demand snapshot 已被 remove/replace 时直接丢弃，不得写 failure/source projection；不同 plugin 仍并行。
repository load/device scan/inspect 等 transient work 不进入该 gate。
registry 只负责 runtime session/deactivation 次序，不承担它不可见的 physical payload identity；
runtime host 对 admitted installed record 的 cached/fallback inspection 必须只读该 `InstalledExternalPlugin.payloadPath`，
且 inspection path 必须与 record path 一致，不能再通过 mutable pending map 解析运行时 payload。
进程崩溃后的 final preview orphan 不能用“当前 manifest 未引用”目录 sweep 猜删，因为 `.bak/.invalid` 恢复代可能仍携带有效 ownership；
若扩展 crash recovery，必须先建立 durable pending proof。
持续打开的 `SourceManagementScreen` 仍通过窄 `sourceProjectionChanges` + `readExternalPlugins/readExternalSources` 跟随 controller/source projection，
但 repository/editor 可持有导航时的 current concrete controller：
正常 App runtime 的 core-service adoption 不得改变其 identity，
不应为此把整个 `HomeServiceHandoff` 或 lifecycle owner 下沉到 nested UI。
resolver-visible source list、`CachedBrowsableComicSource` decoration、
session source publication与source-confirmed canonical comic-id持久化则由独立 `HomeSourceProjection` 持有；
它只接收普通 `BrowsableComicSource` 集合并显式追踪当前 external source identities，
不依赖 plugin controller/runtime，也不得用 Mihon/Venera 前缀反推 external ownership。
source projection 只复用底层 producer、response cache 与创建时 transport generation 都相同的 decorator；
实时 transport generation 仍由 producer 提供。普通 browse 不因无关来源列表变化刷新或重置分页，聚合列表变化继续退休旧聚合请求。
`SourceBrowsePage` 可携带来源只读 `nextOffset`；adapter 验证严格前进，Presentation 消费该请求坐标，未声明时按返回项数推进。
Mihon 以对齐 offset/limit 映射 native page，完整保留原生页；空页的 hasMore 和下一坐标仍归来源，不新增分页缓存或调度 owner。
durable handoff先构造候选source projection并完成`HomeLibrarySession.adoptServices`；
library、chapter download、download composition 与 whole-comic queue 的唯一当前authority由`HomeLibrarySession`持有。
`HomeServiceAdoptionCoordinator`只负责把`HomeServiceHandoff`发布的一代服务按 single-flight 顺序交给 session，
并在 session 已确认 adoption 后原子切换同代 `HomeServiceCacheBinding`、source-resource binding 与 source projection；
它不持有 Flutter presentation/navigation 状态，也不成为第二个 service authority。
`HomeShell`只触发该 coordinator、读取 session/projection 并持有 Navigator push/pop 与直接 presentation 状态，不保存平行 mutable service generation。
进程内的 route admission bookkeeping 由纯 Dart `HomeRouteAdmission` 持有：Reader 覆盖标记、Download Manager 单实例槽和 comic identity route lock 都从 Widget State 移出；
它只决定“能否进入/是否覆盖”，不构造 route、不调用 Navigator、不读取 library/cache/source/download/version owner。
comic/source preference 与 chapter read-state 的 durable write-through 也由 session 持有：
捕获 concrete library identity 执行写入，跨 adoption 成功或失败均等待 current service adoption 后重试；
helper 返回稳定写入的 library identity，caller 在无 await 的同步 continuation 再确认仍是 current 后才发布 projection。
批量 comic preference（例如书架 reorder/alias neutralization）必须先完成同一 current store 的该批 durable writes，
再一次性发布 Home projection，不能退回 UI `save* + replace*` 或逐项 rebuild。
Home 的 canonical alias 查询只在单次调用内按同来源 raw comic ID 去重；共享漫画 ID 的章节不重复解析 source identity。首页同次同步构建只聚合一份当前漫画库，更新与历史列表分别过滤排序；更新先检查只读更新证据，再对候选合并别名偏好。查询继续采用当前 source authority 优先、已保存 canonical ID 离线兜底，下一构建重新读取，偏好合并顺序不变，不持久缓存别名。
同一 stable mutation owner 也覆盖 session-owned chapter、SavedComic 与非 Reader progress write-through；
chapter/SavedComic 的 write+readback 必须在同一个 concrete store 内完成，
跨 adoption 时整轮重试 current store，caller 同步确认 persisted store 仍是 current 后才发布 Home projection。
Reader 高频 progress checkpoint 例外：
仍走 `ReaderProgressCheckpointStore.enqueueProgress`，不得为了普通 Home write-through 一致性把翻页回调改成等待 durable write。
production bootstrap `LazyImportedLibraryStore` 也必须实现该 checkpoint capability：
durable 尚未 materialize 时只保留 per-chapter latest checkpoint 并异步触发 single-flight promotion；
`flushProgressCheckpoints`/Lazy `close()` 必须等待 promotion、转交 SQLite checkpoint writer并形成 durability barrier，
promotion 失败不得清掉 pending，后续 flush 可重试；
Lazy close 必须 single-flight/joinable，并在 admission 时立即 fence 新 enqueue/durable mutation，
内部只允许已接纳 checkpoint promotion继续完成。
`unawaited(saveProgress)` 只保留给真正不实现 checkpoint interface 的兼容/test store，App 不得另建 pending-Future owner。
category mutation 同样由 session 持有，但 remove 不是单记录删除：
必须在同一 concrete current store 完成 remove 后读回 categories 与 ComicPreference cascade proof；
Home 只把“目标 category 消失/受影响 preference 去掉该 categoryId”这一语义合并进当前 projection，
保留其它并发 preference 字段，并一次 publication 同步更新 category+preference projection。
public `reload`/`ensureReady`/`retry` 与 service adoption 还共享同一个 admission 次序：
reload admission 捕获当时 in-flight adoption 并在任何 current-store reload/open I/O 前 join；
adoption admission 捕获当时 in-flight public reload 并在 service swap 前 join。
先被接纳者先完成，禁止 old-store reload 与 durable handoff 交错发布，也不新增第二 generation/listener owner。
reload query snapshot 在最终 publication 前还必须再次比较 `_libraryProjectionRevision`：
若期间已有 session-owned mutation，entries/saved/version/categories/readStates 保留 current projection；
comic/source preference 只允许合入 reload 自己新建的 defaults，same identity 以 current 为准；
`activeSourceId` 必须从最终 source-preference map 重新计算，旧 query 不能回滚 concurrent mutation。
reload 合成的缺失 source/comic preference 只是 baseline，不是用户更新：
必须保留 factory epoch `updatedAt`，不得用 `DateTime.now()` 抬高 LWW 优先级；
因此 stale missing-preference query 即使晚到，真实用户 preference 仍在 durable store 与 Home projection 两边获胜。
cache侧由单一generation-bound `HomeServiceCacheBinding`同时绑定Reader artifact cache与`ResourceCacheCoordinator`及其close ownership；
该 binding 与 durable-adoption single-flight 均由 `HomeServiceAdoptionCoordinator` 持有。
session未采用候选generation时 coordinator 回收 Home-owned candidate cache；
session已切换authority后即使后续reconcile报告错误，也必须跟随已采用generation而不能回到旧binding。
same-service但source/cache projection变化仍要更新session source list；
handoff single-flight结束后 coordinator 重检最新published generation并继续drain，避免飞行期间的目录切换/service rebuild被吞掉。
`HomeShell.dispose()`先 fence coordinator 的新 adoption，再由 composition teardown drain close 前已接纳的 adoption continuation；
该 continuation 若启动 committed source-migration recovery，
recovery 由 Widget composition 保持 single-flight tail 并在 teardown 中继续 drain。
只有这两条 composition tail 都完成后，才进入 Home-owned Reader/version lifecycle teardown：
先 close `HomeReaderChapterComposition`，封闭新的 Reader prepare admission 并 drain 已接纳的 service handoff → hydrate → source-locator refresh → version-authority preparation → response-capability projection；
再 close `HomeVersionReuseLifecycle`，之后才依次关闭 external-source lifecycle、
`HomeLibrarySession`、source-resource gateway 与 owned cache。
这样已开始的 DeferredReaderRoute load 不会在 Home dispose 后继续触碰已关闭 source/version/session owner；
Reader preparation 没有新增第二取消协议，只等待已接纳 prepare 自然完成，底层 source/network deadline 仍由既有 owner 管理。
不能先关闭 reader/version/external/session owner 再让 adoption/recovery 或 admitted Reader prepare 尾段继续运行，
也不能把 source/cache/projection continuation 下沉进 session close。成功后才原子切换projection/cache引用。
Home 的书架“管理/批量选择”模式由纯 Dart `HomeShelfManagement` 持有：
它只维护 managing、batch-selection 与 source-aware comic identity selection 的 UI 不变量，
不读取 `LibraryComic`、library/download/source owner，也不拥有 Navigator/BuildContext/dialog；
Widget State 继续负责渲染、确认框和实际 library mutation。
HomeLibrarySession 的完整章节 upsert 保留持久化回读与最新 progress；逐字段比较完整持久化 payload，只有真实变化才刷新媒体 authority。回读值与传入不可变记录完全一致时复用其已准备 manifest；实际变化仍采用回读记录，canonical assimilation 保持原提交路径。
Reader 章节进入前的 preparation 由独立 `HomeReaderChapterComposition` 持有；
`DeferredReaderRoute` 先显示加载页，composition 在 load/hydrate、
版本 authority、response 能力与 Pipeline 构造前 await core services + Home adoption，
避免捕获随后退役的 bootstrap cache/download owner；失败由加载路由报告，不回退旧 owner。
此等待不属于 Reader/UI 网络准入、不等待无关插件启动，trace 用 `serviceHandoffMs` 单独记录；
它只接收显式 hydrate/source-gateway/transfer-runtime/version-authority/read-marker/trace capability，
不持有 `BuildContext`、Navigator、Widget State 或任意 `_HomeShellState` 字段。
`home_shell_reader_route.dart` 只保留导航、route-local recovery 与 UI callback，
不能重新实现章节 preparation 或直接取得 transport/cache/session owner。
Home 的 chapter/whole-comic 下载命令由独立 `HomeDownloadCommands` 顺序化：
它每次从 `HomeLibrarySession` 取得当前 chapter/queue generation，负责 durable handoff、hydrate/source-authority refresh、
placement readback、stale-token bounded retry、cancel/delete/pause/enqueue；
其中真实删除正文/下载文件的 delete 必须先完成 durable service handoff，
纯 library metadata remove 不因此强制打开 durable download services；
详情 conflict dialog、导航与完成 presentation 仍留在 UI adapter，`part` extension 不得直接重新拥有这些 service mutation。
source/version migration 则在用户完成比较确认后交给独立 `HomeSourceMigrationTransaction`：
prepared fingerprint/journal、exact target chapter preparation、
verified artifact reuse、SavedComic/偏好/进度/已读状态 commit 以及 committed cleanup/recovery 均由该 owner 持有；
但 durable write-through 继续委托 `HomeLibrarySession`：
target read-state 使用 `persistReadState`，source cleanup neutral preference 使用 `persistPreference`，
transaction 不再 direct save store + manual projection。
它始终通过 `HomeLibrarySession` 读取当前 library generation，并额外接收一个窄 `ensureDurableLibrary` capability：
`recoverCommitted`/`resumeCommitted`/confirmed execution 在任何 source-migration journal lookup 或目标 library 读取前都必须先跨过 durable core open + session adoption，
避免 bootstrap journal 与 durable metadata split-brain；owner 不认识 `HomeServiceHandoff` 类型。
其余只接收 current artifact-cache provider、verified-page-reuse identity 与 preference/canonical-id 等窄 capability；
事务结果只携带结构化计数/状态，目标选择、版本浏览、比较确认与结果文案/提示均属于 UI，Widget State/`part` 不得重新持有 journal/metadata transaction authority。
同源版本关系发现、page-reuse proof/warmup、显式“查看同源版本”的 selected-target preparation、
Reader 首帧后的低优先级 metadata/version refresh 与 Reader version authority fingerprint 由独立 `HomeVersionReuseLifecycle` 持有；
UI 只在版本 route push 前请求 preparation、在 route finally 释放 token，Reader 通过 lifecycle 查询目标 chapter 对应 preparation；
`HomeShell` 不再保存 selected version 的 `originComicId + Future` 镜像状态。
该 lifecycle 每次通过 `HomeLibrarySession` 读取当前 library/chapter-download/relation generation。
版本准备先由同一 session hydrate 已有章节，再对完整结果应用来源 locator 检查；hydrate 后重验取消，有效 manifest 直接复用，缺页或旧 locator 仍走原来源刷新和 upsert。
stored successor/predecessor 必须在同一个 concrete `session.library` identity 上成组读取；
任一 await 后 library identity 改变或旧 store 因 adoption 被关闭时整体重试，
只有 current identity 自身 I/O 失败才向上抛出，禁止一次 Version State 混合两代 relation projection；
无需持有 `HomeServiceHandoff`、`libraryGenerationChanges` 或额外 epoch owner。
relation durable write 则统一由 `HomeLibrarySession._persistVersionRelation` 持有：
ordinary relation 与 derived page-reuse evidence 在 concrete library store 写入、
canonical assimilation 后都重验 library identity；若 adoption 跨过任一 await，先等待 current service adoption 收口，
再把同一 relation 重写 current store，只有 current identity 自身写失败才传播。
该 helper 返回实际稳定持久化的 library identity，caller 在同一同步 continuation 中再次与 current `library` 做 identity check 后才更新 session relation projection，
关闭 Future 完成与 projection publish 之间的 handoff 窗口。owner 只接收 fresh metadata snapshot、verified page identity、
统一 source-locator validity predicate 与 metadata-task scheduling/cancellation capability，
不反向 import `ComicDetails` UI DTO、source gateway 或 app-global coordinator。
Reader refresh 仍由 composition 把任务提交到 application 共享 NetworkLane priority100，
controlled `TaskControl` 路径不得加入无 control 的 generic warmup；
lifecycle 自己只记录其 exact task key 与已接纳的 warmup/version/background Future，
close admission 立即拒绝新 work、优先取消尚未启动的 queued refresh、
对 active refresh 只通过共享 NetworkLane 的现有 `TaskControl` cancellation 发信号，
并 drain 已接纳 work 后才允许 external source/session owner teardown。
`_versionViewReusePreparations` 仍是 route-local UI token，不能下沉为长期 version authority。
Download Manager 在 Home 路径只把 chapter service/queue 当作只读 projection/change source；
所有 download/retry/stop/delete-files 与 whole-comic queue mutation 通过 `DownloadManagerCommandActions` 注入 `HomeDownloadCommands`，
命令 owner 每次从 `HomeLibrarySession` 读取当前 generation，并在 mutation 前跨过 durable adoption。
route-open 时传入的 concrete chapter/whole-comic/cache service 只作为首帧 projection/subscription seed；
长生命周期 route 监听既有 `HomeServiceHandoff` change signal，
以 generation epoch 失效已 resolve 的 binding，下一次 service-side read、
cache inspect/trim/clear 或 standalone fallback mutation 必须重新 resolve/adopt current generation。
handoff 若发生在 resolve in-flight 期间，旧 resolve 完成后必须继续 resolve 新 epoch，不能由 one-shot resolved flag 吞掉；
cache clear 在用户确认 dialog 之后才固定 current coordinator；
standalone/test fallback 跨过任何会让 generation 改变的 UI/数据 await 后都必须在 mutation 前重新 resolve：
whole-comic policy dialog 在用户确认后 resolve current queue，
chapter action 在 `hydrateEntry` 完成后 resolve current downloads；
避免 modal/hydration 期间 generation change 后写回旧 service。
Home `commandActions` 路径仍直接委托 generation-following `HomeDownloadCommands`，
不得因此额外增加 post-await concrete route-service resolve。
`HomeLibrarySession` 在构造/adopt 时统一正规化 `ChapterDownloadTransferRuntimeProvider`，
Reader route/version-reuse consumer 只读该 composition capability，
不再从 `ChapterDownloadService` 向下探测 `PartialDownloadStore`/transfer provider。
`apps/app` 的 Home 关键路径只等待能产生封面的本地库 primary 数据和内置来源。入口直接挂载 memory-backed Home；
首个Flutter surface可见后异步打开durable/native/plugin capability。
`HomeProjectionSnapshot`同时保存Home primary、SQLite projection revision和需要持久展示的manual/auto-cache chapter-download summary。
存储 owner 在 worker handoff 前只投影快照的持久字段；既有 isolate 执行 JSON 编码与压缩，普通章节的完整 pages/prepared manifest 不进入 worker 输入图。
durable catalog/preference/read-state DTO 的 JSON 字段转换也留在该 worker；caller 只准备 compact entry metadata 与不携带 prepared manifest 的 orphan 页字段。
orphan download entries 仍保存完整页元数据；写入串行、完成屏障及临时文件替换由原 snapshot store 拥有。
revision匹配的durable handoff只切换authority并targeted revalidate这些已持久download identities，
禁止为了Home启动扫描全部library entries或执行orphan discovery；后者属于Download Manager/用户显式刷新。
Download Manager 首次打开 Canonical/自动缓存页若缺 physical cache projection，
只通过 `HomeLibrarySession` 请求 downloads owner 的窄 cache-management projection；
该读取复用 durable index/physical inventory 构造 Canonical/Exact 行，但不为全部 library entries 逐页重建 chapter snapshots。
cache identity 仍按 exact source/comic/chapter/revision 保留；若旧 source revision 与当前 library chapter 仅 generation 不同，
downloads projection 只复用当前同逻辑章节的人类可读标题作为 presentation metadata，并显式标记 historical revision。
Download Manager 不把 opaque plugin id、raw source id、Exact/Canonical 等存储术语直接当用户字段；historical exact cache 可清理，但不得被提升为当前手动下载目标。
手动孤立下载与自动缓存共用downloads owner的单次metadata选择；无关联记录显示通用标题。冷Home摘要与删除确认只选安全标签，不改exact snapshot或命令目标，不解析plugin payload。
cache-management 行只允许由 durable exact index 或 durable physical artifact/partial inventory 建立；transfer runtime 的 hot session 不属于该 projection。尤其 `file/content/asset` 的 source-resident promoted session 仍由原始可重开来源拥有正文，普通 Reader 重读不得因为 session 被 retention 保留而重新出现在自动缓存，也不得为此物化第二份正文。
后续 durable management invalidation 仍使用完整 management projection 收敛 chapter lifecycle；
完整 refresh 一旦开始会 fence 更早的 cache-only publication，不能把 cache-only fast path 扩成第二状态 owner。
无可信snapshot时才允许一次full recovery reconcile。
targeted/full reconcile更新后先比较真正持久化的download summary/orphan projection，无变化不得重写snapshot；
这移除了此前设备上56-entry同步projection约895ms+3.26MB snapshot encode/gzip约289ms的无效启动竞争。
队列和章节下载增量仍通过Home独立download projection更新水印，不得重发library broad notify。
durable artifact/cache owner 在 exact READY promotion 或 canonical physical partial checkpoint 真正提交且 mutation generation 仍有效后，
必须发布独立 management-projection invalidation；
Download Manager/Home management projection 只能把该信号当作重新读取 durable inventory 的触发器，
不能把旧内存 projection 当 authority，也不能在 stale/rollback 分支误发。
外部插件在capability handoff后后台恢复，source尚未ready时外部封面保持pending，source projection single-flight释放owner时必须重检尾部change。
`HomeLibrarySession.close()` 一开始必须用 `_closing` 立即封闭新的 reload/adoption/stable library mutation/source replacement/version-relation admission，
但不能提前发布 `_closed`。`hydrateEntry`、`hydrateChapterBatch` 与 `ensureCanonicalMediaForEntry` 虽从读取/authority 补全进入，
也会更新 version-authority cache 并可能追加 canonical-media write/backfill tail，因此同样属于该 admission；
close 后新调用必须拒绝，close 前已接纳 hydration 必须把 canonical continuation 完整排空。
constructor `_ready` 属于隐式 pre-admitted work；
所有 close 前已接纳的 public async operation 由非串行 active-admission owner 持有到完整业务 continuation（durable write/readback、
projection/canonical publish、snapshot schedule）结束，admission 只计数/drain，不能把并行 hydration 变成全局队列。
close 先等 `_ready` 与这些 admitted operations，再排 version/canonical/snapshot tails，
最后才置 `_closed` 并关闭 owned SQLite/library；
whole-App `checkpointSnapshot()` 是 teardown durability barrier，不属于普通新 mutation admission。
`HomeShell.dispose()` 只启动异步 composition close，`ChangeNotifier.dispose()` 必须在该 close 完成后执行，不能抢先取消已接纳快照。

`MainActivity` 显式创建关闭自动 `GeneratedPluginRegistrant` 的 `FlutterEngine`，并在 Activity 结束时销毁；
仅覆盖 `configureFlutterEngine` 不能阻止 implicit engine 的构造期注册，feature bridge 只能通过 startup channel 按能力挂载。
`LocalMediaBridge` 在 Android 的 pick/scan/open/read 入口前共享 single-flight attach，
保证从持久阅读记录直接进入 Reader 时也先注册 `dev.zic/local_media`；startup channel 不存在的宿主才回退其自身的 eager registration。
按类名反射的 Android feature plugin 及 rhttp 入口必须由 app 的 R8 keep 规则保留原始全限定名。
Android 存储根目录优先随 Dart entrypoint args 同步注入，避免冷启动首次 MethodChannel 往返；旧宿主才回退轻量 startup channel。
Android 的 durable/native/plugin capability 只能在 `FlutterActivity.onFlutterUiDisplayed` 已确认首个 Flutter surface 实际显示后打开；
Dart `postFrameCallback` 或“已经 rasterized”的调用方假设都不是可见性证据，也不得据此提前放行重 I/O。该阶段不创建第二份 owner。
首次安装的 `app_preferences.json` 不在 Home 启动时强制写入；偏好控制器先使用内存默认值，用户首次修改时才创建持久文件。
`AppPreferencesController` 负责持久化 `ThemeMode` 与 AMOLED 深色开关；
`MaterialApp` 只在有效深色主题下应用 AMOLED 纯黑 surface/scaffold/canvas，首帧加载背景不再强制切换为浅色。
App 根路由的返回确认由 `_RootBackExitGuard` 拥有：
它以 `PopScope(canPop: false)` 包裹 Home 根路由，首次系统返回只显示“再按一次返回到后台”提示并开启 2 秒确认 Timer；
窗口内再次返回仅通过 Android startup channel 请求 `moveTaskToBack(true)`，
保持当前 Activity、FlutterEngine、Dart services、Reader/transfer owner 原位存活，
不等待 checkpoint、service close、偏好 flush 或任何 durable I/O。根返回是导航/后台化动作，不是应用 shutdown barrier；
不支持该 Android capability 的宿主才回退 `SystemNavigator.pop()`。真正 service/runtime close 仍按各 owner 自己的 teardown 合同收尾。
守卫只挂在根路由上，其他路由、对话框与漫画源页内部返回手势（含其 `WillPopScope`）先于该守卫消费返回事件。

新安装且不存在 imported-library、offline-cache 或 whole-comic queue 状态时，Home 不打开 SQLite 或创建 WAL/schema；
`LazyImportedLibraryStore` 先提供内存投影，首次 chapter、收藏、已读、偏好或进度写入时迁移到持久库。已有 durable state 的服务仍在 Home 可见窗口之后打开；
Reader checkpoint writer 的第二个 WAL 连接也只在首次真正写入 `ReadingProgress` 后懒启动。
SQLite schema 11 在 schema 10 的独立 `chapter_read_state` 基础上新增 `source_migration_journal` 控制表；
`chapter_read_state` 继续作为独立的来源章节身份状态，不再用指向 `imported_chapter` 的外键阻止未 hydrate 章节先写入已读状态；显式删除章节负责清理章节、进度和已读状态。

已有 durable state 时，`HomeProjectionSnapshotStore`先读取上一次成功reconcile的Home投影；
bootstrap Home只读该快照，SQLite仍是章节、进度、书架、偏好、分类、已读和版本关系唯一事实源。snapshot revision匹配时Home primary直接复用；
显式App退出在其它Reader/download/plugin owner静止后、library close之前flush最终Reader progress并强制`checkpointSnapshot()`读取最新revision，
保证下次启动不会因退出尾写误触发authoritative reload。compact entries不复制完整page locator；
Reader/下载/版本迁移前再由authoritative library hydrate。snapshot损坏/版本不兼容/读失败静默回退SQLite。
snapshot序列化仍是加速器而非事实源，真实状态变化异步原子写回；无变化的download校准不得制造重写。

`HomeLibrarySession` 先发布 entries/SavedComic primary，再读取 enrichment；启动期缺失的来源/漫画默认偏好只加入内存投影，用户明确修改时才持久化。
已挂载 Home 的 chapter/SavedComic mutation 必须通过该 session write-through。
外部 artwork 的恢复/cache权威只有 `ComicSourceResourceGateway/ResourceCacheManager`：
presentation取得不可变 `EncodedResourceSource` 后只建立一个 ImageProvider；
response cache持久文件不得借给 Flutter，跨 cache 边界必须物化为 presentation 自持有的 encoded bytes。
只有导入的稳定本地文件可使用 `FileEncodedResourceSource/FileImage`。Future/ImageStream失败保持稳定占位，
普通 rebuild、App resume、timer/watchdog或 ImageCache eviction都不得自动建立第二套请求。
首页 artwork 的冷 miss 在 encoded bytes 到达后可先返回 memory source，durable response
写入由 `ResourceCacheManager` 后台排队；同一批封面按卡片独立完成，不等待全部封面或
全部持久化写入。gateway以 source-confirmed canonical comic identity探测 durable artwork
namespace；命中时不解析 source、不创建 plugin transport，miss才进入真实 source loader。
raw Mihon locator继续只用于插件 request/chapter identity，不参与 durable artwork分区。未访问的
首页、书架、来源和杂项页由 lazy indexed page 保持未构建，避免隐藏导航页提前创建第二套
封面 loader；访问过的页面状态仍由该页面节点保留。

Home 的“更新漫画”投影只取已在书架且具有 source-confirmed update 的漫画。章节/目录更新由 `SavedComicRecord.sourceUpdateAt` 表示；
同源版本更新由 `HomeLibrarySession.versionRelations` 中 source-confirmed predecessor→successor relation 的首次 `discoveredAt` 表示。
两者是并列事实源，presentation 只读合并后的有效更新时间；版本关系不得再镜像写回 `sourceUpdateAt`，阅读进度也不得推进任一更新事实。
首次入架把当前已知版本记入ComicPreference的可选acknowledgedVersionComicId；相同successor不再产生首页提醒，后续successor仍可提醒。普通偏好编辑保留该值，同源迁移保留、跨源不搬foreign identity；family heads与relation/reuse独立。
普通 metadata刷新、阅读进度与仅浏览记录都不产生更新。漫画源卡片从同一 Home/library 投影读取书架与更新事实：
左上书架标志+变暗只表示当前 raw/canonical comic已入书架；右上感叹号只提示该书架 comic有 source-confirmed update。阅读历史
单独按 `ReadingProgress.updatedAt` 投影。

### 详情页与来源迁移组合

`ComicDetails` 只把详情展示、阅读进度和用户命令投影到 Flutter；详情 AppBar 不重复显示
漫画标题，标题只在详情内容区出现。保存过阅读进度时，继续阅读命令直接调用既有
`onOpenChapter` facade，按钮和阅读历史是两个独立的 UI 投影，并位于章节总数行上方；详情页不创建第二个阅读器或
正文缓存。来源浏览、manifest/chapter 身份校验和 `ComicSourceMigrationPlan` 比较由
`_HomeShellSourceMigration` UI part 组合；确认后的状态迁移、artifact 复用和 durable recovery 由
`HomeSourceMigrationTransaction` 经 `HomeLibrarySession` 与既有 cache owner 完成。
远程与本地详情共用同一章节 presentation：
章节目录直接以 `SliverList` 接入外层 `CustomScrollView`，只构建可见及缓存范围的行，不嵌套全目录 shrink-wrap 视口。章节行沿用 source/chapter presentation identity 和既有交互回调；目录元数据、进度与下载 authority 仍由原 owner 提供。
章节完成态优先由真实 `ReadingProgress` 与已知 pageCount 推导，到达最后一页或倒数第二页即视为已读并整体弱化，未完成进度保持正常亮度并显示“读到第 N 页”，进入章节本身不再写已读；
用户右划的显式“标记已读/恢复未读”通过 `ChapterReadState.manualOverride` 保留为独立 durable override，
因此旧版本“进入即已读”的普通 state 不得覆盖现存未完成 progress；
来源目录新增加的 chapterId 由 `SavedComicRecord.unseenChapterIds` 持久投影为标题前圆点，第一次点击进入即消费，初次建立目录 baseline 不产生新章节圆点；
来源若提供 chapter `updatedAt`，该时间随 `Chapter -> SavedChapterRecord/ImportedChapterRecord` 保留，
详情优先显示 source timestamp，否则回退本地 imported/catalog sync 时间，compact Home snapshot 必须保留这些字段；
无命名来源标签组直接渲染 chip Wrap，不建立仅用于显示“标签”标题的父层。

详情内容标题通过独立 `onSearchTitle` 命令进入 `ComicTitleSearchPage`，保留原详情 route。
首帧后命令既有 external-source lifecycle 发布来源，route消费其只读投影通知；该页按已启用且可搜索的 sourceId 分组，新激活源加入当前查询，原组Future/分页保持。
各组独立消费既有 source browse Future、canonical page projection与共享 artwork loader；
查询、分页和显式重试才创建请求，build 不重发。旧查询/已退出页面的回包不再发布；来源 runtime、cache和取消仍归原 owner。
点原漫画结果返回原详情，其它结果沿既有详情入口；标签仍走 `onSearchMetadata`，退出详情/聚合栈到 Home 的该单源搜索页。
`ComicSourcesPage`在首次挂载前接收已有`requestedQuery`，初始化原query/controller后才开始source读取；已挂载页仍由`queryRevision`消费新的查询命令，不另建路由或请求owner。
JM 浏览链接由 Venera source adapter 将数字/`jm`数字 ID 投影为 `https://18comic.ink/album/<id>`，合法绝对 HTTP(S) ID 保留。
该浏览链接与 JS 更新地址和 canonical identity resolver 分离，不更换 source website、comic/chapter identity、locator或 artifact authority。

同源版本关系只来自来源 `ComicVersionSource` 或已持久化的 `ComicVersionRelationStore`；Venera/E-Hentai按来源关系生成版本，
`HomeVersionReuseLifecycle` 将来源声明的新版保存为 current→successor、旧版保存为 predecessor→current，均经同一 `HomeLibrarySession` 提交；不按标题、日期或展示序号推断版本顺序。
关系发现保留已有首次发现时间与 page-mapping proof；唯一最新版仍由已确认的有向关系决定，未确认分叉保持无唯一 head，不放宽正文复用。
版本发现的gallery HTML由source adapter显式标记`loadResource.sourceDocument=true`，经既有`Network.fetchBinary`返回native-byte token；
它共享来源session、Cookie、requestId和物理invocation gate，但不进入thumbnail/image hook、图片签名校验或图片语义恢复。普通页面/artwork保留默认图片资源边界。
不得用标题 `browse` 推断同源。通用“迁移漫画源”入口允许选择当前来源或其他已启用来源：跨源标题搜索只用于候选发现，
同源面板只展示来源确认的 successor/predecessor，并同时提供“查看”与“迁移”。查看直接打开目标 raw identity，不改变状态；
通用确认版本列表消费既有只读首显与source-owned background Future，刷新在当前dialog发布、失败保留首显，关闭不取消owner工作；选择保留精确版本对象。relation discoveredAt只表示发现证据，不能投影为来源更新日期；未知日期省略，实际来源日期随刷新发布。
迁移无论同源/跨源都进入唯一 `ComicSourceMigrationPlan + showSourceMigrationComparison`，
比较卡片展示标题、作者、来源/章节与由Home既有`ComicWebUriSource`能力提供的普通Web地址；缺失地址只省略该行，不解码或展示内部identity。内部identity仍用于封面seed、比较plan和精确事务目标，确认前不写用户状态。
只有 exact chapter match复制偏好、阅读位置和已读状态。查看路由只使用 `source-version-view` temporary route identity；
同源替换完成后新 raw locator成为实体并清理旧 alias preference/metadata。
已确认同源版本或显式迁移的 page-position relation持久化为compact `ComicVersionPageMapping`：
`successorOffset`在bounded首/中/末anchor证明成功后表示整个两章重叠区的affine page alignment，
`verifiedPredecessorPageIndexes`只保存最多3个anchor provenance而不是逐页cache白名单；
mapping同时绑定predecessor/successor sourceRevision和pageCount，结构事实不连续即不能组合/复用。不存在10分钟周期重验证：
普通 Reader/后台对当前chapter/revision/count仍匹配且anchor proof非空的mapping直接复用；
只有用户显式选择查看某个target version时，selected relation才可按持久`intervalProbeVersion`做一次当前interval模型迁移重验，
并且必须先按`targetComicId`过滤relation，禁止把同漫画全部历史版本同步重验。
mapping缺失时zic可在Reader首帧后的当前chapter single-flight后台准备最多3个anchor；
显式version-view preparation可只为selected target在目标physical demand前等待该proof。Reader lookup/miss绝不逐页source验证。
page-mapping derived write仍只更新authoritative relation+内存baseline，不发布Home broad notify/snapshot。
Reader冷恢复先batch hydrate当前chapter涉及的唯一历史source chapter，
再按accepted offset构造aligned exact key集合，调用persistent artifact store的targeted `getMany/IN`一次筛出实际READY与indexed partial；
同时只读composition runtime现存session，并通过runtime唯一`hasReusableEquivalentPhysicalState` authority判定hot physical是否可join（source-resident非artifact-cache body明确拒绝）。
只有source侧存在READY/partial/joinable-hot且target exact尚无durable/hot session的pair注册`ArtifactCacheManager` bounded symmetric in-memory equivalence（现有8192上限），
不注册lazy future-page resolver、不持久化page alias、也不扫描整库。
`lookupAuthoritative`/exact write/invalidate和`PersistentDownloadArtifactStore.openArtifactStream`始终exact-only，
命中fallback必须保留真实source `storageId/generation`。
显式migration要求target exact durable时仍可通过既有metadata-only `artifact_id` binding零复制materialize，
不能改写physical authority或继承source pinned。
manual/export adoption消费同一accepted affine mapping但仍必须匹配sourceRevision并通过predecessor `ExportPageBinding.logicalIndex -> pageId`唯一定位READY record；
页面自身strong identity仍可直接证明candidate，same pageId跨revision、文件名ordinal和CRC单独都不足以建立等价。partial格式和owner不改：
exact partial绑定自己的DownloadId/URI validator；
跨equivalent前缀恢复必须清空旧validator，physical reuse只在acquire边界发生，artifact commit不得late takeover。
详情头部先投影已持久化的 successor/predecessor 关系，来源版本发现只在后台校准并更新持久关系。
正文喜欢、书架、收藏、下载整本保留统一 48×48 `_PreferenceButton` 尺寸与 `filledTonal` 外观，不得因不可见版本槽或整组缩放产生来源间尺寸差异。
版本入口位于顶部 AppBar 的“迁移漫画源”图标左侧并直接复用该行 `IconButton` 风格；
无关系时只保留标准 action 宽度的空槽，仅有新版、仅有旧版、新旧并存时分别使用正向、倒置、顺时针90度的感叹号。版本面板在新/旧列表间原地翻转，行标题直接查看详情、行尾迁移图标直接进入既有对比；
不得显示 opaque comic ID、伪 generation 编号或再弹出版本次级选择菜单。
持久关系首显后的 source refresh 必须二次发布到当前详情和已打开面板，不得要求退出重进。面板中间的“迁移到当前版本”是真实命令：
只有当前版本存在不同 canonical identity 的 predecessor 时才可用，并直接进入既有迁移对比。
同源替换在移除旧版本记录前，必须将已验证等价且已持久化的旧页面 artifact 写入目标 exact DownloadId；等价关系仍不是 hard alias/rekey，无法证明等价的字节不得复用。

漫画源页使用来源自身声明的 browse section：
Mihon 映射 Popular/Latest，标准展示顺序为“最新 → 热门”，Venera 枚举 explore loader 与 category target；
Venera `multiPartPage.load(null)` 返回完整分组集合，由 runtime adapter 按全局 offset 切片并仅以集合余量判定结束；普通页码 load 和既有 loadNext 游标合同独立，不修改插件返回对象或新增分页缓存。
首次进入来源时默认 section必须由**当前展示顺序的第一项**决定，不能另写 `popular` 默认值，也不能让最近一次 catalog cache projection反向选择 UI。
未来用户自定义排序若改变 Presentation顺序，同一排序 owner自然同时决定默认焦点。原生/Mihon/Venera 仅通过来源 chip 的背景色区分，不显示 JS/插件图标，也不占内容分类行。
`FilterableBrowsableComicSource` 只投影来源真实 `FilterList`：空 schema即没有筛选入口，不另设容易漂移的 capability布尔值。
Mihon bridge必须按官方 `Filter.Header/Separator/Select/Text/CheckBox/TriState/Group/Sort` 基类继承关系识别插件自定义子类，
并保留 Group层次与 Text/Sort状态；用户修改以类型化 filter-state override进入 search request。筛选是否激活是独立 Presentation/request mode：
空 override表示使用插件默认 `FilterList` 状态而非“未筛选”，激活后分类栏焦点属于“筛选”且请求不继承 latest/popular section；
Catalog cache identity与runtime payload必须显式区分 filter mode和普通 section mode；
筛选草稿的寿命是单次弹层调用，应用/取消后结束；route 或 IME 重建不得重置尚未应用的修改。
external browse的 typed factory、wire validator与 adapter payload必须共享同一字段契约，
schema v1新增 `useFilters` 可缺省兼容但未知字段仍拒绝。Filter不得伪装为 `SourceBrowseSection`，浮动搜索只拥有 query与搜索历史；
搜索展开与输入只更新自身 listenable 子树，IME inset只按“键盘高度减去浮层原始底部净空”的实际重叠量移动搜索浮层，
不得压缩或重建 catalog 网格，固定搜索浮层和底部来源栏保持独立 repaint boundary。键盘 inset 的递减由浮层自身观察并释放搜索焦点，但保留搜索面板，使下一次返回只关闭面板且不得重新请求 IME。
普通搜索历史的嵌套滚动复用页面已有收起处理；扩展搜索选项列表仍可滚动选择，上方手柄继续独立控制选项展开。
browse projection revision 只属于 metadata，不能作为整页 artwork reload token；
`ComicSourcesPage` 的来源刷新只退休该来源当前 Future 身份上已观察的 source/decode 失败，保留健康和 pending 封面 Future；
source失败沿原 loader重试，decode失败才转成既有一次性 gateway精确刷新。迟到失败只记入仍对应的 Future，不触发自动请求。
source card 的 Sliver child 与内部交互祖先 key 都使用来源确认的 canonical comic identity，raw locator变化不得重置封面 State。`sourceComicCardKey` 接受 canonical identity；点击命令仍读取当前 summary 的 raw locator。
固定大小的 catalog page 仍使用显式上一页/下一页，pager 位于内容滚动尾部。
列表由 catalog response cache先行投影，但 cache只能服务**当前精确 UI 请求**，不得用“最近 projection”改写 section/query/filter默认状态；
`ComicSourcesPage`切换时先原子绑定目标 source并按当前请求读取精确缓存；没有访问状态快照也不跳过该读取，miss直接投影目标 loading/error，旧 source内容没有展示资格。schema到达后若section/filter改变请求，原`requestChanged`分支清除失配投影，再读取新请求精确缓存。旧请求的迟到失败受原generation fence约束。后台 refresh只有在稳定字段发生变化时才更新 Presentation；
边缘下拉达到刷新阈值后强制绕过缓存请求来源，但保留当前内容直到新数据到达。Mihon 插件的已安装与仓库列表仍按规范化语言分类。

详情页与漫画源页的统一刷新由 `AppPullToRefresh` 拥有 edge trigger、72 px位移、进行中状态与成功/失败结果图标；页面不得叠加第二套刷新状态。

详情入口采用 stale-while-revalidate：若 `CachedComicDetailsProjection` 有热 manifest，页面先同步投影漫画和章节，并复用已缓存的首屏预览/评论；
主详情请求和可选预览/评论请求在后台刷新。Presentation 按漫画字段、章节列表、预览页和评论页分别比较，只替换发生变化的那一类，失败的可选请求保留旧投影。
内嵌在新 manifest 中的首屏页只在强制主响应刷新后同步到对应分页 key，分页独立刷新不会被普通主响应命中覆盖。
预览图/头像的编码字节仍归 `ComicSourceResourceGateway/ResourceCacheManager` 的 artwork 路径，不归 catalog metadata cache。
同一详情 route 的 `route-push`、`details-first-frame`、`deferred-source-ready` 因果 trace 必须使用 composition-owned monotonic clock；
独立组件测试/嵌入场景可以回退到组件本地时钟，但不得把不同 epoch 的时间戳混在同一跨组件时序结论中。
详情首帧不得等待下载状态、artifact index、章节 page I/O、跨版本 page mapping proof，或 deferred external source activation。
已有持久化详情投影时必须先 push route 并完成详情首帧，外部 source activation 只能从下一次 post-frame 异步启动；
source 后续到达时原地更新同一个 `LocalComicDetailsScreen` identity/State 及其 source-dependent capability，不得重建详情局部状态或要求退出重进。
未持久化章节在source缺席时等待同一路由既有activation Future，完成后重取live resolver；已有chapter记录不等待该Future，详情已dispose则停止materialize。
章节状态检查在首帧后以 `inspectMany()` 批量读取；跨版本关系发现由详情/version-state与Reader后台refresh共同消费同一source capability：
详情不得遍历整本，但version-state发现relation后可异步warm实际有缓存状态的当前chapter。
普通Reader入口只恢复已有mapping并立即进入Pipeline，不得因为mapping缺失或旧proof模型而同步扫描/重验同漫画历史relation；
generic mapping补全留给Reader启动后的异步metadata/version refresh。
只有显式“查看版本”拥有明确`targetComicId`时，reuse preparation才以短生命周期Future传给目标Reader，
并在目标physical demand前只对selected direct relation的当前hydrated chapter执行single-flight bounded最多3-anchor准备；
该selected relation已有当前`intervalProbeVersion`时直接跳过。
普通Reader的chapter metadata/version relation后台刷新必须等首个实际页面presentation frame报告后才启动，
再刷新当前chapter existing-state alias；它不得在首帧source request-plan之前抢占Venera单context runtime gate。
late proof只影响尚未acquire的demand，已存在physical session绝不merge。显式version-view的selected-target preparation仍是例外：
它属于目标physical acquire前的正确性边界，不得被该首帧后移规则延迟。不挂lazy resolver、不为未来页占alias、不在翻页lookup时调用source。
Reader、DownloadSession、NetLane正文与调度ownership不因该后台准备下沉到详情/UI。
详情扩展数据由 source adapter 负责：
`ComicManifest` 可携带首批预览缩略图和评论，`ComicPreviewSource`/`ComicCommentSource` 只在来源声明能力时提供继续分页。App 只消费
规范化 URI、评论字段和不透明的 `sourceSubId`/回复 ID；
评论正文的受限 HTML 只解析实体、换行和 HTTP(S) `img`，emoji 仍通过统一 artwork loader/cache 绘制，不把原始标签直接交给文本控件。
图片仍走统一 artwork cache，评论完整列表和回复通过详情次级页加载，不把评论请求或插件 transport 变成章节目录的
全局门控。Venera 直接复用 `comic.loadThumbnails` 与 `comic.loadComments`，因此已有 `ComicDetails` 能力的来源可渐进显示预览、评论和回复。
预览 URI 保留 Venera 的
`@x/y` 裁剪标识用于预览项/widget/painter 的单项身份，但 `onThumbnailLoad` 请求回调接收
去掉裁剪标识的原图地址；该 base URI 也是编码字节缓存身份，App 解码后只绘制对应裁剪区域。
预览栏折叠与展开共用同一套顺序布局。实际行含横图时最多 2 张，纯竖图行最多 3 张；只允许在相邻三个候选内做最小局部重排。完整行直接用全部媒体宽度反算等面积 tile，不再把剩余宽度变成外边距或巨大项间距；
标题保留普通内容边距，但图片区不叠加 Card 或水平 border/padding。只有稀疏末行允许相对完整行放大，面积上限为参考完整行的 2.4 倍。外观设置提供详情预览每行最大数量 1–8，默认 4；它不属于 Reader 操作设置。
折叠态只显示同一布局第一行，高度取第一行实际高度；展开态继续消费来源分页，并由 `PageView` 左右分页呈现后续行。行规划消费扣除分页指示区的屏高 90% 预算，过高单行以有界高度求等面积并保持完整行全宽；折叠/展开共用结果，开关位于中间且只显示上下箭头。
行规划使用已解码的可见裁剪尺寸；实测尚不可用时消费 `ComicPreviewAsset.width/height`，两者均缺失时使用正方形占位比例。缩略图使用 `BoxFit.contain`，不拉伸或强制裁切。
预览失败只显示按资源 identity 生成的柔和单色占位，不显示破损图片图标。

App-owned modal panel 的操作行由 `AppDialogActions` 统一投影：关闭固定为左下角 X，确认、
保存或删除位于右侧，不再使用“取消”文字按钮。

### 插件与平台桥

- `plugin_host`：信任、权限、请求计划、身份适配和插件生命周期。
  runtime adapter 独立校验实际响应的 `maxResponseBytes`，字符串键和值直接计算 UTF-8 长度，不为计数物化 encoded bytes；合法 surrogate pair计4字节，孤立 surrogate按U+FFFD计3字节。depth/type、binary/scalar与body-file清理合同不变。
- `plugin_host_bridge`：Android 隔离进程与 Mihon/Venera runtime 适配。
  Mihon漫画输入在runtime内由`mihonMangaInput`转换为SManga：完整opaque模型保留所有来源字段，原生URL原文只补空初始标题；保留的`mihon:`前缀仍严格校验kind。插件调用及响应identity保持原始comicId。
  `plugin_host`按同一source URL解析原生/opaque输入的Web与canonical身份；二者共用既有目录互斥和artwork namespace，UI不构造opaque模型、猜路径或另持identity authority。
  Mihon目录保留source返回的完整对象与newest-first顺序；opaque章节ID仍编码source ordinal，向外sequence投影为oldest-first逻辑序号。
  plugin-host的只读顺序适配兼容旧持久目录，Home composition消费该投影，Reader不解析来源identity。Venera既有sequence合同保持不变。
  同一source+canonical漫画URL的getMangaUpdate在runtime内互斥，等待可被取消；不同漫画仍可并发，NetLane继续拥有网络admission与rank。
  active Mihon invocation取消后等待实际Callable退出；无可取消context的suspend调用先drain continuation，再释放目录互斥与runtime completion。
  Mihon 设备发现只覆盖作为系统共享 APK安装的扩展，合并 `getInstalledPackages`、
  `getInstalledApplications` 与已知仓库 package name的精确 `getPackageInfo`；
  每个候选的 manifest、metadata、签名、ABI与 entry失败必须返回诊断，不得静默丢弃。Mihon App私有 `filesDir` 中的扩展不能跨 App读取，必须从 ZIC 仓库独立安装。
  metadata inspector在候选拒绝及已解析APK校验失败时保留package、metadata键名、declared/normalized ABI与resolved entry文本；
  缺失或无法解析的值明确标为missing，诊断不导出其它metadata值，也不改变候选/加载校验或激活来源。
  原失败message经既有MethodChannel/scan投影到插件页可复制错误区，UI不另查APK或反推ABI。
  APK 候选按扩展 feature 或标准 package prefix识别；
  entry/ABI meta-data随后从 manifest原值或字符串资源解析，多个 entry class可用逗号、分号或换行分隔。
  隔离 runtime 的公共网络 ABI只要求 `AndroidCookieJar` 等稳定适配器，`AndroidBrowserCookieSession` 属于 network bridge内部实现，
  不得被 plugin host直接 import或列入 common runtime必需类。Mihon 1.4/1.6 的兼容 `NetworkHelper.client` 必须保留上游可观察的默认 interceptor ABI：
  canonical `UncaughtExceptionInterceptor` 置于 application interceptor 链首位，随后安装 canonical `UserAgentInterceptor`；
  Cloudflare 位置必须暴露 canonical `CloudflareInterceptor` 类型，但其挑战识别/verification handoff 仍委托 `network_bridge` 的唯一 owner。
  已有 `IOException`（包括 typed verification failure）原样传播，只有后续链抛出的非 IO `Exception` 才转成 `IOException`；不得额外注入 Brotli default interceptor。
  host request-plan能力判断将这三个精确的canonical拦截器类型视为可重放；source-loader所属或未知client能力继续保留runtime路径。
  Cookie/UA仍由source plan同步补入；redirect/Set-Cookie/协议不匹配继续沿同一TaskControl进入既有source-client兼容路径，普通媒体正文保持host streaming。
  Mihon Injekt host service 由 runtime driver 统一注册；当前至少包含 `Application`、`NetworkHelper` 与与 Mihon `AppBindings` 一致的
  `Json { ignoreUnknownKeys = true; explicitNulls = false }`，扩展不得在 Reader/Pipeline 侧补造 host singleton。
  动态 ABI按原始类名加载 `dev.zic.network.*` common 类型；
  所有列入完整性预检的网络类型必须由 `network_bridge` consumer R8规则显式保留类名和成员，不能依赖普通源码引用阻止 Release混淆。
  durable handoff 后已安装插件恢复最多使用 4 个并发激活 worker；
  `plugin_host` 只把最终 session 安装作为短同步提交段，并在提交边界重新检查 source identity collision，慢候选不得占住提交队列。
  manifest 已保存的 payload 元数据可跳过重复 Dart inspection/hash，隔离 runtime 仍必须在加载前校验 payload 长度与 SHA-256；
  设备 Mihon 扫描可与插件激活并行。漫画源页底部控件只投影已经产生活跃 source session 的插件；
  已安装但未启用/激活的 Mihon 或 Venera 只保留在管理页，不得作为 disabled 来源控件出现。typed denial/runtime code判定不可恢复时才回滚新记录并删除新 payload，
  可恢复失败保留记录和 payload并由管理页或仍有旧 session 的控件触发同一 pluginId 重试，replacement 失败继续保留旧 session；从漫画源管理页返回不得等待后台库重载。
  插件管理页进入时由 `ExternalPluginController.checkUpdates` 按安装时持久化的**精确仓库索引**检查更新（版本号优先比较，无版本号时版本串不同即可更新；
  仓库索引与 executable-plugin gate 使用的 HTTPS trust origin 是两个独立事实，禁止把只有 scheme/host 的 trust origin 当 index 请求）。旧 manifest 未保存精确 index 时，仅对能够由 pinned payload URL 无歧义证明属于历史默认 Keiyoushi/Venera 仓库的记录迁移到当前默认 index；设备导入和无法证明来源的记录不猜测。单个仓库不可达不掩盖其它仓库结果，发现更新以对话框提醒一次并在已安装行保留徽标，仓库行对已安装且可更新的条目显示"更新"。已安装 Venera 插件支持直接编辑 JS：
  `readVeneraJavaScript/saveVeneraJavaScript` 把编辑内容写入新 revision payload、
  重新经过受限元数据检查并以新摘要固定后走与安装相同的 approveAndActivate 事务替换会话，检查或激活失败时旧 payload 保持权威。
  插件管理中的版本与Mihon ABI只从既有安装记录/设备扫描元数据投影；设备扩展的长包名与版本ABI分行布局，失败态仍保留已知安装信息。来源主列表只投影来源名称、语言及站点，不查询安装记录；UI不扫描或镜像元数据。
  来源管理页是单一未分类的可拖动排序列表（`_buildManagementEntries/_managementList`）：
  Mihon 同扩展多语言变体按 `mihonSourceGroupKey` 折叠为一行，行代表 = 最近启用变体（`ComicSourcePreference.lastEnabledAt`），
  点击行首插件图标展开其余变体，`_enableMihonVariant` 在启用时自动停用同族其它变体；
  排序写入既有 `sortOrder` 偏好并决定漫画源页底部控件顺序——底部 chip 按偏好序遍历已启用源、每个插件族在其首个代表源位置只发射一枚 chip。
  Venera 保持单 WebView、单 invocation 生命周期；
  可能等待 origin 的 `Network.*` 通过 `ZicNative.requestAsync` 回调执行，不阻塞 JavascriptInterface 线程。
  HTTP文本输出与`Convert.decodeUtf8`共用UTF-8解码边界，消费一个开头的BOM；正文中的U+FEFF与原始二进制body保持，GBK路径独立。
  激活只等待源代码显式 `await` 的请求，激活期间遗留的后台请求由下一次 invocation 的 activation-work gate追平；
  `requestId` 取消与 runtime close 均先取消 resolver transport，且只有 JavaScript `finished(requestId)` 后才结束调用边界。
  Venera `Image` bridge MUST保持参考实现语义：`fillImageRangeAt` 的零宽/零高range是合法no-op，真实source/target越界仍拒绝；
  Android Canvas不得以静默裁剪替代Venera边界检查。rhttp client 在 runtime service ready 前 warm-up，但实际激活耗时仍受 VPN/源站网络路径影响。
- `network_bridge`：浏览器、Cookie/localStorage 快照、challenge 恢复和共享网络能力。
- `bridge`：Dart FFI、native source/cursor/frame ABI 和两个进程常驻 decode isolate。
- `texture_bridge`：Android texture lease、SurfaceProducer、单 lane RGBA blit、schedule 和 release；
  SurfaceProducer创建/销毁与scheduleFrame由平台线程执行，MethodChannel result从对应完成lane回包。
  output release先撤销native登记，再由blit lane释放resident frame并投递平台销毁；回包不测量GPU/fence退休。
  已承载output的lease随output退休，只有从未呈现过的prewarm lease可进入idle pool。
  精确尺寸的 idle prewarm 在同一 blit lane 先 materialize surface，
  并用 acceleration-only native prepare 预配置目标 RGBA geometry。
  prepare 只减少首个真实 blit 的平台配置成本，不能取得 surface correctness authority：
  每次真实 blit 仍独立读取/校验 ANativeWindow geometry，并在失配或 lock recovery 时自行配置。
  满池时只淘汰最旧 idle lease，不能把 surface 初始化或无界资源持有转移到 Flutter UI。
- `apps/app`：composition、导航和产品页面；不得定义资源算法。
  Android storage platform bridge 将 **path/tree/namespace** 与 **read-only descriptor open** 分成两个执行域：
  单线程 `zic-saf-path` 只串行 SAF path resolution/namespace mutation；
  App-private Direct 与 SAF 的 `presentationOpen*`、read-only `safOpen`/prewarm 统一进入 bounded `zic-local-read-open-*` pool，
  已打开 descriptor 再按 handle stripe 保序。Direct cache presentation 不得因为桥入口历史名为 `handleSaf` 而落入 SAF path FIFO；
  Flutter/Dart 的 `ArtifactCacheReadScheduler` 仍是本地正文读取 admission/priority owner，
  平台线程池只负责避免无关 path work 阻塞 descriptor open。
## 4. Reader 数据流
- Reader/media presentation remains source-neutral during stale-carrier recovery.
  `PipelinePageStream` may project a terminal typed `Failure`,
  and `LocalImagePlayer` may forward that opaque error through its existing presentation-recovery seam,
  but Venera/source-generation interpretation stays in App composition.
  App may refresh chapter/page authority only for a terminal semantic source failure with no source-owned replacement plan;
  only the currently visible raw page may automatically trigger that refresh, once per logical page in the Reader route.
  The old Reader remains mounted while the fresh chapter is prepared. The resulting source generation is nevertheless chapter-scoped:
  after the failed page proves a real carrier change, every old logical page must map one-to-one onto the same fresh list and the matched carriers
  are rebound atomically while old page structure/order is preserved. Persisting only the failed page would mix two carrier generations under one
  `sourceRevision` and leave sibling Pipeline tasks pinned to deterministic terminal failures. Missing/duplicate explicit page identity,
  chapter/revision drift, or a no-change failed carrier is fail-closed instead of becoming a retry or content-migration owner.
  The post-first-frame metadata/version task may obtain a fresh source chapter snapshot for version/reuse analysis,
  but it is observation-only for `pages[]`:it must not persist or replace Reader transport carriers.
  Whole-chapter carrier mutation remains owned by App composition's explicit source refresh,
  legacy-locator migration and the bounded terminal source recovery above.
  A `PipelineReaderSessionHost` chapter is immutable across every input consumed by the session,
  including page URI, dimensions, byte length, content-kind/animation hints and checksum facts.
  Rebuilding the host is necessary but not sufficient for reuse safety:
  the two-minute retention pool may use its coarse key only to locate a candidate,
  then MUST compare the full `ChapterManifest` session input before resuming it.
  A candidate with changed page carrier or metadata is disposed and a fresh session is created;
  identical manifests retain the existing reentry acceleration.
  Venera `venera-resource:` 是 exact provider request carrier，不是 physical-media proof：
  同一 `comicId/epId/pageId/sourceRevision` 在真实 jm 设备样本中可随 carrier 返回不同 encoded CRC，
  且 720×3572 RGBA PNG 解码后像素 SHA-256 也不同，因此不得从 logical page/revision 预先生成 canonical `PhysicalMediaId`，
  也不得因 URI churn 零网络别名到历史 READY。`DownloadId` 必须继续包含当前 hydrated manifest 的 exact URI；
  只有已有 version-family projection 或 strong locator/content proof 才能共享 physical owner。
  无authority的非file opaque URI不参与路径/内容hash推断；producer payload中的偶然hash或`/s/`片段不构成physical proof。
  不可变 `ImportedChapterRecord` 在自身生命周期内复用同一个只读 manifest 投影；新 record 独立生成投影，避免 authority refresh 重复解析未变化的整库 URI。
  Home 的完整 source `upsertChapter()` 即使 revision/pageCount 未变也必须替换 hydrated authority 的 fresh provider locator，
  同时保留更新的 Reader progress；compact snapshot/progress projection 仍不得覆盖完整 manifest。
  Details composition 可以用同 source/comic 下按 chapterId 或唯一 sourceRevision 找到的历史完整 page list 作为页数 presentation candidate，
  但 candidate 不等于 hydrated command authority：
  只有 sourceRevision 相同、已知正数 pageCount 与 pages.length 一致且不是 Home placeholder 的 entry 才可直接进入 Reader/单章下载/读状态等正文命令；
  否则命令必须经 source chapter hydrate。
  Details的Home章节准备先定位exact source/comic/chapter并由既有session hydrate完整持久记录，再应用相同revision/pageCount和source-locator检查；有效记录复用且保留导入时间及最新进度，缺失或无效记录仍由来源加载并upsert。
  `zic-home-snapshot-page:*` 这类 compact placeholder 只属于 Home/bootstrap projection：
  不得成为 VersionPageAuthority/canonical media authority，
  也不得进入 Reader/download `ChapterManifest`、`DownloadId` 或 source resolver；
  任何正文消费前必须先 hydrate durable full chapter，若仍是 placeholder 则由 source authority refresh，
  仍无法取得真实 locator 时在媒体 demand 建立前 fail closed。
  schema-19 只退休短暂错误版本写入的 `volatile-page:v1` physical binding，保留 exact READY、artifact object 与 replica。
  - Sealed partial→READY 的跨 filesystem/SQLite 边界由 schema-17 `artifact_promotion` 记录事务进度，
  但最终 sealed authority 仍只有 `artifact_object + artifact_replica`。
  journal begin 必须发生在 sealed partial DB proof 已落地之后、正文 rename 之前；
  store open 只枚举 journal 行并按记录的length/CRC验证 source/destination，绝不读 final sidecar。
  最终 metadata commit 在单个 SQLite transaction 内发布 object/replica/exact READY/canonical physical binding、
  退休 physical partial 并删除 journal；journal pending 时 source/destination 都只是受保护候选。
  same-process duplicate store owner 的 marker guard 必须先于 journal recovery，
  避免一个本应拒绝的第二 opener 推进第一 owner 的 promotion。
  同一 `PhysicalMediaId` 不得长期同时发布 READY `physical_media_artifact` 与 `physical_partial`：
  一旦 READY replica 已通过正常 preflight 成为可读 authority，旧 partial 只剩冗余恢复状态。
  bind/READY-open 路径必须触发 persistent-store-owned retirement；
  `openPhysicalPartialDownload()` 这类 partial 读取/恢复入口若发现 READY 已占优，
  只能返回 no-partial 并把 retirement 调度给同一 persistent owner，禁止在 read path 内直接删 body/row。
  store open 还要异步只比较两张 SQLite 表的 key 交集以收敛历史重叠，禁止扫文件树、禁止阻塞 open。
  retirement 必须在既有 physical-artifact→physical-partial 串行域内重新确认 READY generation，hot borrowed partial 必须跳过；
  正文/sidecar 删除并确认 absent 后才能移除 partial row，失败则保留 row 作为下一次 retry authority。
  该清理使用 `StorageWriteScheduler`，不得由 Reader route/App exit 触发或拥有。
- Static/fallback presentation 的实际容器类别由当前 physical generation 的 Pipeline metadata prefix/classification 拥有，
  manifest/URI 的 WebP/GIF hint 只能参与未决分类，不能在已有 authoritative fallback 之后继续否决 static presentation capability。
  若 durable artifact backend 已提供 generation-checked `openEncodedPresentationFile()` lease 与 intrinsic dimensions，
  静态 presentation 应直接把该 encoded file capability 交给 engine，避免先把整包 encoded body 物化进 Dart；
  真实 WebP 仍由 Pipeline native output/streaming path 拥有。
  positive static evidence MAY 在稳定 3/7 encoded window 内建立 `targetWatermark=1` 的 one-frame Decode/Upload intent，
  但 intent 数量不是执行并发：`StagedDecodeRefillPolicy` 只释放当前最高优先级的未满足 one-frame work；
  fallback/GIF 由 Reader-local ingress 权威分类后终结 native decode branch，
  并通过 `PipelinePageOutputStream.externalPresentationRequested` 投影 exact external-presentation permission。
  `LocalImagePlayer` 不得因 mounted、`transferActive`、文件存在或 manifest hint 自行 `_load()`；
  只有收到该 exact request 后才启动 Flutter decode/presentation。
  该 load-once 资格必须绑定 `PipelinePageOutputStream.externalPresentationCacheIdentity` 所代表的 exact presentation generation，
  而不能绑定 widget 生命周期。presentation raster identity 还必须显式包含由 Reader 上报、Pipeline 转交的 typed fit fact：
  `contain` 受 viewport physical width/height 双轴约束；纵向 stitched `fitWidth` 只受 physical width 约束，
  page host 的高度由 source aspect 决定，绝不能把 viewport height 误当成 long-page raster height 上限。
  mounted `MediaRasterImage` 与 detached external prewarmer 必须调用同一 raster-key policy，并共同进入 composition-owned `PipelinePresentationRasterCache`；
  它以同一个 `ImageStreamCompleter.keepAlive()` 持有已解码 raster，不复制 RGBA，并作为 Reader external-static 的唯一 residency/LRU/admission authority。
  mounted managed-static consumer 只可持有当前 `ImageInfo` 作为屏幕呈现引用，不得再通过 Flutter `Image`/`ScrollAwareImageProvider` 建立第二套滚动调度或 `TickerMode` private keepAlive；
  Pipeline撤销external presentation permission时，mounted consumer必须同步释放该`ImageInfo`，从而使cache owner的eviction真正完成。
  Flutter 全局 `ImageCache` 只是 provider decode/backend 与非 Reader 图片缓存：managed raster admission 后其 generic keepAlive key 必须移除，
  且 manager 已占用的精确 raster bytes/entries 必须从全局 ImageCache 可用额度中扣除，二者共享同一个 100MiB/1000-entry presentation envelope，禁止形成两套独立预算。
  Pipeline 只向该 owner 投影 cache claim：`far/detached` 为 `speculative`，`next2/next/previous/near/last` 为 `deadline`，
  real viewport/current/transition 为 `protected`；cache owner 只可在压力下回收 speculative entry，并在真实回收时主动发送 exact invalidation。
  budget eviction后对同一identity的speculative re-admission backpressure也属于该cache owner；claim升为deadline/protected时才解除。
  mounted与detached首帧消费者均消费该准入事实；Sliver/PageView挂载的屏外listener不得绕过owner denial重新取得grant。
  Pipeline不得再维护`evicted-while-far`等镜像tombstone去猜测owner何时允许重建。
  Pipeline 不得通过 `ImageProvider.obtainCacheStatus()` / `ImageCache.statusForKey()` 轮询 residency，也不得用角色提升做被动 cache revalidation。
  `externalPresentationSatisfied` 只是当前 manager residency proof；owner 的真实 eviction 会主动撤销它并让既有 staged refill 在需要时补帧。
  cache eviction 只改变 residency，不是 presentation generation 边界，MUST 保留原 `externalPresentationCacheIdentity`；
  DecodeDemand/UploadDemand 离开 3/7 调度窗口同样只是 demand gap：claim MAY 降级/释放，但 identity MUST 保持稳定。
  source/recovery/force-reload 或 fit 改变才可旋转该 identity。Reader route retention/reentry 同样不是 presentation generation 边界：
  retained `PipelineReaderSession` 可以销毁 page host/PageOutput/native decode/upload 并释放 presentation claim 以释放 Reader-local working set，
  但 MUST 保留 composition-owned presentation cache identity；若同 raster 仍由 manager resident，mounted consumer先按该identity直接attach既有completer/key，
  不得为了确认同一resident raster先重新打开encoded presentation file或重读encoded bytes；只有owner不再resident时才回到正常encoded acquisition。
  fit 改变时才旋转 Flutter presentation cache identity / first-frame proof并经既有 staged policy 重授，
  不得借此改变 DecodeId、source/download identity 或建立新的 scheduling owner：
  同一 `LocalImagePlayer`/`PipelinePageOutputStream` 在 DecodeId/source generation rebind 后若 opaque cache identity 改变，
  必须允许新 generation 再次启动一次 load；旧 generation 已开始/完成不能成为抑制新 grant 的证据。
  较新的 identity 可借既有 local load generation guard 淘汰旧 in-flight 结果，但不得因此产生新的 retry/transport/policy owner。
  每次artifact-cache presentation read同时产生不可变`storageId + generation` authority；file lease/bytes与该authority属于同一次读取结果，
  presentation decode失败必须回传原authority，禁止按page id查询“最近一次读取”的generation后再失效缓存。manual force reload没有旧read token时才由cache owner解析当前authority。
  external-static 的 presentation generation 与 raster residency 必须分离：`PipelineReaderSession`拥有 DecodeId/source/fit 对应的 opaque presentation identity，
  `PipelinePresentationRasterCache`独占 decoded raster 的 residency/LRU/keepAlive。ordinary eviction/demand loss 不旋转 identity；mounted adapter 必须撤销本地 attempt/provider 后允许同 identity regrant，且 detached resident provider 必须直接 handoff、禁止再次 resize/providerFor。
  `PipelinePageOutputStream` 的 external presentation grant 必须作为一个不可变投影原子发布：grant内部绑定exact `DecodeId`，Presentation只看到cache identity、unavailable/requested/ready与acknowledgement token；兼容requested/ready/cacheIdentity getter只从grant派生。`requested -> ready`保留同一ack token，不得分步通知制造可观察的`(false,false)`；ordinary same-cache-identity revoke/regrant必须得到新token。
  mounted first-frame 必须携带实际消费的grant回到`PipelinePageOutputStream.reportExternalPresentationFrameReady(grant)`，由output先验证ack token仍为current，再由pipeline_runtime读取grant内部私有的exact `DecodeId`完成session satisfaction；Presentation不得获得DecodeId getter，也禁止仅按PageAsset反查“当前”DecodeId。`LocalImagePlayer`的first-frame去重、error、recovery与最终状态发布都绑定不可变presentation attempt（local load epoch/token + grant token + exact read authority），不能绑定整个widget lifetime；旧attempt异步结果在任何await后若已失去current身份就只能退出。
  managed raster decode error 与 ordinary residency eviction 也是两个事件：cache entry 可以退休，但不得在当前 consumer 收到 error/原 read authority 前同步发 eviction 销毁错误通道。没有 exact artifact authority 的 presentation error 不得据此 reset durable/source generation；只有带原 read `storageId + mutation generation` 的拒绝才进入 `DownloadTransferOwner` destructive artifact recovery。详见 ADR 0337。
  `PipelineReaderSession.dispose()`必须与retention共用claim释放边界，并额外注销composition presentation-cache invalidation listener；全局cache不得因已销毁session遗留listener/claim而保活Reader。
  `LocalImagePlayer`取得file lease后立即进入finally保护，late cancellation不能漏lease；widget async load 只使用本地 `loadEpoch + token` 作为 race fence，禁止把它解释成 source/artifact/presentation generation。
  GIF的Flutter codec由单一串行frame-fetch生命周期拥有；pause/resume只能改变循环输入，不得并发调用同一codec的`getNextFrame()`，loading→ready也不得通过widget key变化重建codec。
  实际首帧回报才满足该 watermark；通用LiveCoordinator的speculative external grant缺省仍为1，
  Reader profile显式允许最多3个offscreen external-static first-frame并行pending，
  新的visible/current/transition不计入该speculative cap且可抢占后台等待。
  不得恢复 96MiB estimated static-output eligibility、固定 current/+2/-1 static gate 或 presentation-owned priority gate。
  纵向 Reader 的 measured dimensions 改变真实页面 extent 后，即使没有滚动事件也必须在新 layout 后重发同一观察链的真实 `visibleCoverages`；
  `UploadDemand.viewportVisible` 是由该 observation 派生的 typed presentation fact，不能从 current/next/previous role 猜测。
  external first-frame 的有界并行只约束 speculative background：
  Reader当前最多3个offscreen grant，多个真实 viewport-visible fallback仍可越过该cap并行取得presentation grant；
  若尚未首帧的 visible grant 在期间离开 viewport，LiveCoordinator 必须撤销该 pending grant 并重新释放 speculative refill，
  禁止 stale grant 继续制造黑屏。
  这只修正 geometry observation→Pipeline staging，不给 Reader/UI 增加 decode/network/retry owner。
  native decoded/upload residency 由 `FrameBudgeter` 拥有；
  Reader external-static fallback raster residency 由 composition `PipelinePresentationRasterCache` 拥有，并通过 `ResourceCacheCoordinator.presentationRasters` 统一 inspect/trim/clear。
  App将同一owner绑定为`PipelineStaticPresentation`，其cacheAuthority/prewarm供Pipeline使用，同一capability显式传给mounted UI；展示与预热不得固定选择process-global实例。capability只保存不可变owner引用，不复制residency/claim/LRU状态（ADR0351）。
  capability只委托resident lookup、diagnostics和viewport resize/managed wrapping，不拥有第二份residency或scheduler；exact resident直接handoff，普通local raster只消费纯resize函数。
  同owner的新capability值不更换mounted attempt；owner更换沿既有loadEpoch/token退休旧绑定，旧异步尾部不得发布到新展示。
  generic Flutter 图片缓存与该 managed raster plane 共享 100MiB/1000-entry presentation 总额度，但不参与 Reader role/claim 决策；
  encoded speculative I/O 继续由共享 `SpeculativeEncodedReadBudget` 拥有。
- Reader navigation只提交 observation/用户命令并消费只读输出，不直接操作 transport/session/artifact/lane/frame/texture。
  强制重新加载完成physical reset后只通过per-asset presentation revision替换当前`_ReaderPageShell`内容；
  ReaderView必须保留其它page slot、ReaderController、navigation/zoom与DemandPlan，
  新的presentation重新attach同一只读PageStream/PageOutput并重报媒体能力。
  纵向 `targetCoverage` 只能来自真实 viewport 内的非 current coverage；
  `ReaderVerticalGeometry.positionAt()` 的 `index + page-local fraction` 不是 PageView 页间插值，
  只有 current 可见时 target 必须为 null，禁止再用通用 `logicalPosition.ceil/floor` 推导隐藏 target。
  真实仍可见的 outgoing page 可以继续作为 transition 直到离开 viewport。纵向媒体比例与Sliver layout owner解耦：
  ReaderVerticalGeometry只拥有item extent/prefix/anchor/navigation；
  Presentation对已知source dimensions必须独立保持source aspect，continuous fitWidth不得把父盒暂态aspect通过BoxFit.fill写入媒体，
  暂态不匹配只允许trailing-edge裁切/留白。
  Reader item extent与Media presentation的最终aspect必须消费同一physical sourceCanvas authority：
  `PipelinePageStreamSnapshot`只读投影`sourceCanvasWidth/sourceCanvasHeight`，
  `LocalImagePlayer`收到后作为authoritative presentation dimensions；
  output/surface decoded raster只做pixel carrier，不得形成第二套aspect owner。
  dev.297基于subpixel量级的bounded-fill/pixel-snap已被设备幅度证据否证并回滚；真实/暂态parent aspect差始终走aspect-preserving fit。
  UploadDemand membership只拥有presentation claim/retention identity；新的upload/present执行资格由`prepareOutput=true`表达；
  已成功authoritative static projection的方向无关连续性可在current±2 presentation envelope内跨directional decode-plan gap保留，
  但不得创建decode/upload/present或改变2/1 decode policy，不拥有既有静态UI projection生命周期：
  authoritative static surface在upload-demand gap中只有当同一DecodeId仍存在于既有decode plan且仍有presentation listener时才可保留；
  该保留不得创建upload/present/decode工作，离开decode plan、identity/generation改变、真实dispose或最后listener移除必须释放。
  纵向异步ratio在finger-owned drag/ballistic/settling期间使用scroll-stable snapshot：沿higher-index方向，仅严格高于visibleMax的future ratio可直接提前采用；
  沿lower-index方向，仅严格低于visibleMin的incoming ratio可提前采用，
  且因其改变viewport prefix必须在同一次layout以top-anchor `geometryCorrectionTarget`原子修正ScrollPosition；
  真实visible页ratio通常冻结到idle；slider scrub是例外，因为它是绝对page-index导航而不是finger-owned content drag。
  scrub中slider-selected page是显式center anchor；所有已知`index <= anchor`的source ratio必须立即进入layout，
  因为任一prefix extent都会改变绝对page-index的物理offset。已真实visible的post-anchor ratio也必须立即采用。
  ratio提交后立即重发coverage；若新暴露页的ratio已在pending中，下一layout pass继续消费，不等待新dimensions event或pointer-up。
  pointer-up只结束input phase；selected-page center继续锚定放手后才到达的尺寸，pending map暂时为空不代表尺寸已知。
  真实content motion、新的page/viewport命令、direction或Controller更换才退休该既有导航锚点；不等待下载/首帧，也不延长scrubbing。
  内部页入口与slider复用同一绝对center anchor；index绑定原navigation revision，入口回执后仍消费晚到ratio，真实motion、新命令及direction/Controller更换退休该锚点。首/末页入口保留边界对齐。
  idle viewport、DPR及stitch变化继续消费该center anchor，以投影的新geometry在同一layout校正。DPR替换ScrollPosition时，首个dimension pass也消费同一pending correction及真实ScrollMetrics范围，不新增锚点状态或以jumpTo产生内容运动。
  普通idle/content-scroll采用其余新ratio时，top-pixel offset仍通过ScrollPhysics/ScrollPosition的layout-time scroll correction与新content dimensions原子收敛，
  不得先换extent再以`jumpTo`制造可观察中间页。
  idle位于可滚动章节真实尾端且无slider center anchor时，ratio/viewport/DPR变化保留tail语义；同一ScrollPhysics layout-time correction从新ScrollMetrics读取包含系统insets的maxScrollExtent。首端/interior及无独立尾端的短章保持原top anchor。
  implicit insets单独改变scroll范围时，同一physics仅在Controller已报末页、无pending page/viewport命令且idle时保留旧真实尾端；显式命令、controller更换、slider center与真实motion优先。
  物理pixels观测、scene诊断与top-anchor准备只使用ListView当前捕获的不可变geometry；帧末采用的新ratio在下一list build前不得解释旧pixels。连续header更新从同一物理anchor累计layout correction，见ADR0361。
  首尾页导航位置由实际ScrollMetrics边界确立；运动速度使用同一已布局geometry的连续视口中心坐标，不把首尾页语义覆盖当作物理位移。采样时钟仍由真实内容运动推进。
  Pipeline在vertical active presentation期间对generic/unresolved以及仍走native texture的non-visible `far/near` speculative static output只defer新presentation work；对应UploadDemand identity继续保留，但`prepareOutput=false`，已有resident output/retention bookkeeping不被当成需要重建的资源；
  既有2/1 decode deadline窗口中的`next/next2/previous`在静态一帧已经decode-ready后必须允许提前进入UploadLane/present，并以`retainOutput`交给FrameBudgeter保留到viewport消费，避免把RGBA→SurfaceProducer首拷贝推迟到visible/transition seam。
  该deadline preupload不扩大2/1 decode或3/7 encoded窗口，仍受UploadLane并发/优先级/抢占与FrameBudgeter约束；更远页仍只在idle阶段恢复普通speculative upload。两个有更强证据的例外仍可在既有3/7 one-frame static intent envelope内提前UploadDemand/present：
  其一是decoder已authoritative判定`animated=false`且encoded body由direct immutable local URI或`residentBodyBacked` immutable authority持有的stable static页；
  其二是当前generation的metadata prefix经`sniffEncodedImageKind`精确确认JPEG/PNG/BMP/TIFF/ICO/AVIF/HEIF等non-WebP/non-GIF image并由Pipeline记录为external-static presentation path的页。
  `ContentKind.fallback`本身不是静态证明，HTML/source错误页不得进入该资格。
  external-static只放开staged first-frame，不得获得多帧deep-decode水位、
  扩大3/7、绕过`StagedDecodeRefillPolicy`或应用于animated/unresolved页；
  该资格不得引入estimated static-output budget，native output由FrameBudgeter裁决；external Flutter raster的residency/LRU唯一归composition `PipelinePresentationRasterCache`。
  Coordinator exact grant若落在尚无PageHost的offscreen external-static，
  可由App composition注入的detached presentation executor消费既有generation-scoped file/bytes capability，并把同一provider identity的一帧admit到统一presentation raster owner；
  executor不得选页、开网络、建立隐藏Reader/Page widget、拥有retry/cache authority或建立第二raster cache，完成后只回报同一grant一次。
  后续PageHost mount继续使用普通`LocalImagePlayer`与同一generation/cache identity；
  current/transition与真实viewport可见静态页继续允许直接presentation，idle后恢复普通stable-role warming。
  Android texture的实际RGBA→SurfaceProducer copy属于OutputFrame presentation而非UploadDemand；
  texture lease必须按具体OutputFrame identity记录当前resident内容。
  对同一retained authoritative static OutputFrame，若该exact frame已有成功presentation timing（历史重复present会标记`platformResidentReuse=true`）且lease/frame未释放，
  presentation role重入只重新取得PresentClaim并直接project现有surface，
  MUST NOT再次调用`present()`制造resident-reuse bookkeeping；
  首次呈现、animated frame、identity/frame变化或lease resize/release仍走正常present。
  SurfaceProducer cleanup/recreate后的重画继续由texture_bridge平台callback owner完成。
  slider scrub的thumb/页码实时跟手，但Reader viewport采用Controller-owned 50ms latest-wins coalescing：
  首个目标可立即推进，时间窗内只保留最后整数页，避免每跨一页都生成navigationRevision/PageView jump与整套Pipeline control churn。
  pointer-up早于最后目标的post-frame回执时，同一有效命令的completion也必须结束已释放的scrubbing；no-op jump无需ScrollEnd即可发布idle。final flush绝对跳转后即同步physical baseline，真实drag/scroll不被覆盖。
  `Interaction.scrubbing`只描述输入生命周期并禁止把这些中间页学习成阅读方向；它不得拥有另一套resource membership。
  Pipeline始终由真实current + vertical visible coverages解析同一7/3工作窗；相邻scrub只能按真实窗口差集增量迁移，
  不得把稳定11-page transport window压成current-only/visible-only后再在松手时重建。
  但membership不等于execution depth：Pipeline把interaction粗投影为`stable/motion/transientPreview` resource phase。
  scrub期间当前/transition/真实visible DownloadDemand保持同一claim但降为`localOnly`，只允许复用/恢复本地authoritative bytes；
  其余3/7 hidden claim为`retained`，不新增remote source work；baseline DecodeDemand/UploadDemand identity同样保留，
  `localOnly -> retained`同时撤销尚未退出的durable local preparation：`retained`是identity-only，旧viewport的restore不得继续占用普通两个bounded local-operation slot或visible-cohort handoff；取消只发信号，writer/descriptor/Future实际退出前slot仍不释放。
  claim removal也必须走同一aggregate execution projection：若最后一个localOnly/full consumer退出后仍有retained consumer，
  session lifetime可以保留，但local restore权限必须立即撤销；新增、更新、移除不得各维护一套scheduler分支。
  visible/current decode最多一帧。ADR 0331进一步区分“外层hidden工作窗”与“既有静态presentation deadline”：
  `next/next2/previous`若具备static资格，可在scrub中继续以`localOnly`取得一帧decode并`prepareOutput=true`，
  用于在进入viewport前写入统一presentation raster owner；该资格不得打开remote source。
  transient scrub把immediate `next/previous`视为selected target两侧对称的representation deadline，二者同优先级；`next2`更低。
  这不改变stable readDirection、7/3方向窗口或方向学习；不得靠增加local/decode/upload worker掩盖priority错误。
  其余`near/far` hidden decode仍使用`targetWatermark=0`、hidden upload仍使用`prepareOutput=false`。
  external-static decode已经ended并把一帧交给presentation owner后，等待first-frame acknowledgement不得继续阻塞下一项staged decode；
  offscreen presentation仍受独立bounded pending gate约束。vertical真实visible transition是可重复viewport role，
  不得被单一transition slot覆盖，其output prewarm与current共享first-frame deadline。
  phase回到stable即使current/visible membership未变化也必须replan，并在同一claim/task上恢复正常full execution；
  已admit physical transport只park为NetLane `demanded=false`/rank0，不得为scrub cancel/reopen。
  velocity/logicalPosition等连续事实不得直接压成跨lane单一权重；encoded I/O、decode depth、presentation prepare、retention与rank必须保留typed projection边界。
  observation到pipeline必须经过enqueue/latest-wins ordinary-event-turn边界；
  不得用microtask让plan/reconcile/lane-pump在当前frame结束后抢占platform/input/vsync事件，
  pipeline reconcile异常不得反向unwind ScrollNotification/page request；
  ReaderBinding必须先推进Reader-local viewport fact，并在reconcile成败后独立同步playback projection。
  `ReaderController`与requested/current page属于route/navigation owner，`DecodeTarget`只属于pipeline/media projection；
  MediaQuery/system UI导致target变化时只更新PipelineController target并在enqueue observation中从既有DemandPlan做增量diff，
  不得detach binding、清空download demand或重建navigation controller。
  纵向continuous的coverage fraction/velocity/logicalPosition属于Reader连续几何事实；slider scrub期间selected page只覆盖navigation identity，
  `logicalPosition`仍来自同一physical `ScrollMetrics + ReaderVerticalGeometry`坐标，但absolute scrub jump本身不是content travel：`Interaction.scrubbing`只同步physical baseline并投影`velocity=0`，不得更新travel direction。
  `Interaction.idle`同样只同步physical baseline并投影零速度；entry整数页号转为viewport-center坐标或idle布局更新不得被学习为content motion，真实drag/scroll仍报告实测速度。
  scrub中若ratio收敛在post-frame阶段再次改变layout，新的`_verticalLayoutRevision`必须由实际重建ListView的frame在post-frame重发physical observation；不得等待下一次pointer事件或在pointer-up才暴露最终center。
  当current/stable、target page、visible page membership与interaction control phase均不变时，
  PipelineReaderSession MUST在enqueue边界丢弃该control-no-op observation，
  不得每帧重跑ReaderBinding/PipelinePageStream/output/artifact scheduler。
  ReaderBinding的vertical active viewport MUST按continuous phase解析，playback只在ViewportState或plan revision改变时同步；
  upload-id page映射 MUST复用chapter稳定索引而非逐observation重建。
  ReaderController的broad ChangeNotifier只拥有direction/rotation/request/scrub等命令；
  current page projection必须通过窄`currentIndexListenable`发布，不得因current跨页唤醒command listener/整套controls。
  纵向page-host current±7 retention半径不变，但active continuous scroll期间keepAlive center冻结，
  ScrollEnd/idle或显式jump一次提交，禁止current每跨页在动画关键帧同步demote远端host。
  dev.318的authoritative-static WebP Flutter projection已被真机有效否证并在dev.319回滚：
  static/animated WebP继续使用统一Pipeline native-texture presentation，
  Reader不得为静态页恢复第二套presentation owner或删除UploadDemand；dev.318只保留`scrollCadenceSummary`诊断证据。
  canonical RoleWindow仍定义encoded前7/后3，但vertical dragging/scrolling/settling的physical DownloadDemand membership允许经active download bridge渐进收敛：
  current/transition/真实viewport以及既有2/1近邻media所需DownloadId必须立即进入；
  完整3/7 static one-frame intent中的far decode/upload不得因此自动升级为mandatory source，
  encoded/far-static desired identity每个新committed current最多前进1个，其余容量可暂存previous speculative identity；
  bridge不得扩大guard后的download总数、不得让decode/upload缺少source，idle/scrub/jump必须完全收敛回canonical 7/3。
  该bridge只削平far transport membership churn，不延迟readDirection/current/visible/transition，
  不修改decode2/1、upload/presentation、NetLane或geometry。Reader控制层的固定底栏只承载页面/旋转/收藏/缓存等稳定动作；
  动画pause/speed作为独立浮动条叠在其上方，媒体从unknown/static到animated的分类变化不得重新排布固定底栏。
  顶部“强制重新加载当前页”只向`PipelineReaderSession.forceReloadPresentation`提交用户命令：
  composition transfer owner负责quiesce当前physical task并在同一个physical `DownloadSession`上换epoch，
  fresh-source quarantine先挡住exact/canonical/equivalent durable restore；
  canonical physical READY/partial routing随该旧physical generation失效。
  普通unpinned cache随后可由fresh generation重新成为cache authority；
  若实际presentation `storageId`或requested exact backend任一表明显式pinned/manual download，
  则exact binding、pin和结构化离线文件保持不变，fresh generation只作为hot presentation authority且automatic handoff不覆盖该exact，
  只有现存required chapter/whole-comic claim才可继续完成exact durable replacement。
  命令成功后Reader只更换该页presentation subtree generation以丢弃旧surface/widget状态，不拥有cache/delete/retry authority。

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

Reader 可以提交 stable page、fractional position、目标页覆盖率、
阅读方向、viewport/physical target、interaction/zoom，以及 pause/resume/speed/jump 等命令。
横向 paged 与纵向 continuous 的 fractional observation 在 current/stable、
target page、target transition visibility bucket、visible page membership、
playback phase 和 interaction control phase 均未变化时，PipelineReaderSession 在 enqueue 边界丢弃 control no-op，
不重复运行 ReaderBinding、策略窗口或 output/artifact projection；播放 phase 与 transition threshold 的离散边界仍立即提交。

Reader 只能消费不可变页面状态、进度、错误和 `PipelinePageSurface`。
它不得接触 mutable session、transport、artifact store、scheduler、cursor/frame handle 或 texture registry。
`PipelinePageSurface.presentationIdentity` 是底层 presentation target 的稳定身份，而不是动画帧身份：
同一 Android `SurfaceProducer` lease 的 WebP 帧只更新平台 texture 内容，Reader/UI 不得因此重建页面子树；
lease、fallback image、尺寸或错误变化仍必须替换 surface 并更新视觉状态。
动画帧通知（包括已有输出的瞬时 `uploading` 与 present 完成回调）不得重新执行 PlaybackGate 或额外触发 UI rebuild；
同一 presentation target 的旧 claim 在平台 copy 完成后立即释放，真正改变 surface/lease/fallback 的 visual claim 才通过 `PipelineFrameScheduler` 合并到每个 frame 的单一 release drain。
已有 surface 的 successor 若在 Flutter persistent callbacks 或下一帧已排队时到达，
只合并最新帧并在该 frame 后提交，首帧仍立即确认，PageView/Reader UI 的 frame 预算优先于高频动画投影。
横向 gallery 的 current/next/transition role 计划可由 Pipeline 在 host 挂载前建立有界 detached output；
该 projection 不等待 upload ready、WebP sniff 或 decode classification，upload ready 后只预呈现首帧，未知 hint 的相邻页也不会错过预热；
paged（LTR/RTL）animated/unresolved 的真实活动手势目标在既有 DecodeDemand 内额外拥有且仅拥有一个 priority-820 first-frame UploadDemand：
稳定方向下的 `next` 仍按原路径工作；若 dragging/scrolling/settling 的 `targetCoverage.pageIndex` 已明确指向相邻 `previous`，
即使 3/7 稳定方向尚未翻转，该实际目标也可暂时取得同一 frame-0 demand。
LiveCoordinator MUST在该role进入prepare前冻结其playback，detached output MAY预呈现frame0到已预建的exact-size SurfaceProducer，
但 MUST NOT推进隐藏successor/播放计时；当其后成为transition/current时恢复同一UploadSession/output，不得重传首帧。
该 active-target 边界不得改变 3/7 方向状态、扩大decode/download窗口或扩展到next2；
idle `previous` 不得因此获得 UploadDemand，vertical Reader仍禁止hidden animated preupload。
该next projection在plan sync与host attach间继续绑定同一DecodeId，禁止临时unbind/prune后重复创建；
manifest、已知 physical content kind 和明显非-WebP URI 后缀已确认的页面不建立无用 native output；
current 且无 listener 或尚无 resident surface 时仍立即预热，next/transition 在 Flutter frame 已提交或排队时延后到 scheduler idle task，
动画/触摸回调未清空前不得启动 platform create，仍继续解码且不改变 playback/freeze 语义，
host attach 后立即同步最新帧。vertical Reader 不启用横排特有的 decode-only animated-next lease prewarm，但既有 real UploadDemand 的 static `current/transition/next/next2/previous` 必须预绑定 detached output consumer，使已经 ready 的 native output 不再等待 PageHost mount 才 `claimPresent/present`；`far/near` 仍不建立该 active detached output。
自适应阅读 profile 的分类 owner 保持在 `reader_runtime`。它消费漫画元数据、非封面页面几何、实测动画证据，
以及 App preferences 按 `sourceId` 投影进 `ReaderSessionSettings.sourceWebtoonConfidence` 的来源级条漫置信。
条漫置信的唯一持久 authority 是 `AppPreferencesController.sourceAdaptiveWebtoonConfidences`：
0 表示强页漫先验、0.5 表示中性/自动、1 表示强条漫先验；Reader 不监听、不回写来源偏好，也不建立插件级第二份值。
旧 `sourceAdaptiveWebtoonWeights=w` 只在读取时迁移为 `0.5 + 0.5*w`，保持旧评分差不变，后续写回只使用新 key。
Venera source 可声明 `comic.adaptiveType=paged|vertical|animated`；该声明经 plugin runtime 的 typed `SourceAdaptiveReaderType`、
App composition 与 `AdaptiveReaderMetadata.sourceType` 进入已有高置信 metadata 路径。
来源名和官网也由 composition 投影给 classifier；Mihon 未声明等价能力时保持 null，不做猜测。
model v8 将页面几何改为一次性小样本判定：最多取 3 张，包含第一页；达到目标样本数后停止 geometry sampling，
后续解码页面不得再次改变布局 profile。`0.65 < height/width < 1.20` 视为异常/transport-slice 不确定区，
因此 `720×700`、`720×500` 自身不再形成页漫票；明显 16:9/9:16 等普通页面才形成页漫几何证据，极长纵幅形成条漫证据。
`韩国/韓國` 等地域标签仍只参与弱证据合成，不升级为硬方向规则。
adaptive profile 是共享的 Reader 行为输入，不是“布局模式”本身。当前消费者至少包括阅读方向与长按放大：
没有漫画级显式方向时，高置信 profile 可以选择分页/纵向方向；漫画级显式方向只覆盖方向这一项，
不得阻止 profile 继续更新或供其它消费者使用。长按放大的优先级为漫画级显式覆盖 >
高置信 adaptive profile 建议 > 模式默认；条漫/纵向 profile 默认关闭，页漫/动图 profile 默认开启。
分页方向的全局 fallback 由 App preferences 单独持久化为 `LTR / RTL / source`，默认 LTR；它只在漫画显式方向与高置信 adaptive 方向都没有给出答案时生效。
全局 `adaptiveReaderEnabled` 与漫画级 `comicAdaptiveEnabled` 共同决定 profile 是否生效，
与“启用本漫画覆盖”的手动 override master 相互独立；自适应入口在 master 开启后仍可见，清除手动覆盖也不清 adaptive policy/profile。后续翻译等能力可消费同一 profile，
但不得因此让 Reader 接管翻译或 Pipeline 调度 ownership。非中性来源置信进入 adaptive profile fingerprint，
中性 0.5 保持原 metadata fingerprint。
Android texture lease prewarm 必须按 source canvas 等比 fit 后的实际 decoded raster 尺寸建立；
DownloadSession 在 WebP 固定前缀解析出 source canvas 后立即触发 current/next/transition 的精确预热；
同一 raster 尺寸的 deferred requests 按 current > transition > next 优先级每个 idle task 最多启动一个 platform create，
idle+pending 总量仍受全局有界池限制；decoded frame 到达后的尺寸只作兜底，预热失败可重试且不得改变 demand/playback 语义。adaptive profile 不得借此改写 NetLane、download/decode window 或 prefetch owner。手势缩放是纯 presentation 行为：
`ReaderView` 拥有 paged 单页 `InteractiveViewer`（双击分级默认 1.5/2.0，两个倍率均由独立 slider 调整 + 独立长按倍率默认 2.0）与 continuous 整条 strip 的统一 `Transform`（双击分级 + 捏合 + 长按放大，
所有页面一起缩放）。全局 Reader presentation/gesture 偏好由 App preferences 按布局保存为两个独立 `ReaderModeSettings`：paged 与 continuous 的连续阅读、双击倍率/锚点、长按启用/倍率/移动/拖动边界和 zoom decode boost 可以分别取值；
只适用于单一布局的分页方向、纵向拼接仍各自保持单一 owner，系统栏等真正全局 UI policy 也不复制。高置信 adaptive profile 可按漫画类型覆盖长按启用默认，
漫画级显式长按覆盖仍最高优先。长按放大支持松手复原/保持释放（仅分页；
连续模式始终保持）、拖动/聚焦两种移动方式、可调拖动比率、双击位置模式（居中/吸附/聚焦）与"最大可视"边界约束——该约束按 contain 后的真实图片矩形计算而非页面控件矩形，
留边轴保持图片居中（契约见 SPEC 2.3）；这些是 UI 设置，不改变 demand/prefetch/texture 所有权或 NetLane 调度。strip 缩放是视口空间视觉层：
点击区域配置也留在同一 mode profile，但 persistence 以 `gestureActions -> singleTap` 分层，而不是一个无手势类型的九宫格。
single-tap profile 除 9 个 action 外还保存归一化的两条横向/两条纵向分隔坐标；同一个
`ReaderGestureGridLayout` 同时是实际 hit-test authority 和编辑覆层的几何 authority，禁止 UI 预览与真实命中各算一份。
Reader 内打开点击区域设置时直接在当前页面上覆盖全屏编辑层并临时进入沉浸显示。编辑层的 9 个 cell 覆盖完整 viewport 并拥有命中，
所以拖线/选动作不能下穿成为翻页、缩放或滚动；底层 ReaderView 的 widget ancestry 不因进入/退出编辑而改变。分隔线拖动的 draft 只在 overlay-local State 中更新，
不逐 move 重建 Reader/Pipeline；保存时才一次性写回当前 mode profile。每次打开编辑器都有独立edit-session identity；
异步保存只能关闭发起它的同一会话，cancel后重新打开的新overlay/draft不得被旧Future完成回调清掉。
全局阅读设置没有真实 Reader viewport，因此只提供 action map/动画表单，并明确实际区域尺寸需在 Reader 覆层调整；两处 action 名称与图标复用同一helper，避免设置入口逐渐分叉。
当前只有 single-tap profile 可编辑和消费；`ReaderPageHost` 继续唯一拥有单击/双击/长按消歧，只有确认不是双击/长按后的
`onSingleTap(globalPosition)` 才跨到 `reader_runtime`。Runtime 只负责用上述可调 3×3 layout 把坐标映射到区域并发出 typed
`ReaderGestureAction`；paged 的上一/下一页仍通过 `ReaderController.requestPage(index±1)`，continuous 则通过 `requestViewportStep` 移动一个可配置的 viewport 比例，默认保留 10% 上下文、滚动 90% 屏幕；两者都只是程序化 Reader command，不伪造 pointer/drag/velocity。章节动作复用既有 chapter-boundary callback。
单击切页动画只决定对应 command 使用 `animateTo/animateToPage` 还是 `jumpTo/jumpToPage`。
程序化vertical command的completion只负责读取最终ScrollMetrics并acknowledge，不再裁决`Interaction`；
真实pointer/ScrollNotification唯一拥有dragging/scrolling/idle，旧动画Future不得把进行中的drag覆盖成idle。
scrollbar scrub/跳页是独立的绝对 page-index 命令：continuous 把目标图片映射到其纵向 centered offset 后定位，不用多次 viewport-step 逼近；scrub、拖动和恢复定位不继承 single-tap animation intent。
以后若增加双击/长按九宫格，必须在 `gestureActions` 下新增独立 sibling，并先由 PageHost 对应 gesture owner 显式上送，
不得让 single-tap action map 抢占当前 zoom/long-press 语义。
Reader 的系统栏 presentation 由 `reader_runtime` 单独拥有，不与 Pipeline/媒体生命周期耦合。`ReaderSessionSettings.systemStatusBarMode` 只读投影全局三态偏好：
`show / hide / followControls`。前两者独立于 Reader 控制栏；`followControls` 只复用 Reader 已有 `_controlsVisible` presentation fact，不新建可见性 owner。
系统 navigation bar 仍跟随 Reader 控制栏显示。Android targetSdk 36 使用 reader_runtime plugin 的 `WindowInsetsController` 作为真实 show/hide owner，
因为 Flutter 旧 `SystemUiMode.manual/immersiveSticky` 在 Android 16 已被系统忽略。route transition gate 只延迟首次 apply，之后控制栏切换/App resume 可重复 apply；Reader dispose 恢复 status/navigation bars。
滚动在放大状态下保持可用且跳页不复位缩放，未锁定时普通单指水平滑动可平移整条 strip；
双击第二下按住仅固定当前倍率与水平偏移，按住期间独占指针并禁用垂直翻页，锁定时水平滑动不改偏移，双指捏合松开保持结果不弹回，已放大时长按仅水平拖动不改倍率；锁定态再次普通双击仅退出锁定，解锁后的普通双击才继续阶段循环；
双击配对用屏幕坐标、阶段用离散索引单调推进（不受动画中间值影响），换级偏移按当前倍率换算锚点保持、动画向目标帧逐帧钳制插值不回跳不越界，
放大态冻结延迟比例提交防止放大镜下内容改尺寸、回 1x 即落盘，仅方向切换/controller 替换等结构性变更复位；
settled scale 经既有 `onZoomScaleChanged` 投影给 zoom decode boost，仅为可视区域提高解码分辨率。

章节 UI 与章节预加载是两个独立边界。Reader 仍保持“一章一个不可变 `ChapterManifest` / `PipelineReaderSessionHost`”，不得把相邻章节页面拼成一个伪 manifest。
逻辑章节previous/next按source的oldest-first顺序投影定义；Mihon旧目录由plugin-host保留的source ordinal兼容适配，其余来源继续按sequence升序。
Home在每次排序开始时为每章投影一次逻辑序号；比较器只比较该调用内的整数，同序号保持来源顺序，不跨调用缓存目录或改写章节身份。
同一次同步Reader screen构建共用一份previous/next查询结果；切章命令和预加载仍重新消费当前canonical目录与完整source-model定位，不把构建期结果保存为目录authority。
当前章与目录先按 exact ID 定位；同一 source/comic 内仅在完整 Mihon source model 唯一一致时忽略 host ordinal/parent locator 定位逻辑位置。URL/name/memo 保持比较输入，不改 runtime/download ID，也不建立正文等价。
Home详情composition以同一source-owned比较键生成不可变的stored-entry到唯一catalog行投影；详情按快照实际章节的source/comic作用域归并页数、进度、已读与同步时间，不以route原始别名过滤快照，重复历史行不再另加计数。
该投影不进入entry复用裁决或打开/下载/删除目标；详情展示可读紧凑快照的已存页数，预览跳章仍沿用原有效页数裁决，占位页面仍不得复用。正文与mutation消费原exact/revision合同，继续阅读保留真实历史身份，来源目录与持久记录不改写。
详情/source展示顺序不改变底部下一章、顶部上一章。跨章首/尾命令由Home composition在hydrate/source refresh后解析成显式initialPage，优先于历史进度；首/末页进入对应真实scroll边界。
vertical初页同步复用Controller绝对页面请求，显式请求覆盖旧idle锚点；目标RenderBox与滚动范围经布局确认后才回执，真实拖动接管即退休旧请求，旧controller回执不得触及新章。
每个 mode 的 `ReaderModeSettings.crossChapterReading` 只 gate 章节边界 UI traversal。paged 使用 PageView 的明确边界 pull；continuous 必须先由 ScrollPosition 的真实首/尾几何确认到章边界，再从边界后的单指 pointer pull 计算提交距离，不能用 coverage-current page 或 Android overscroll physics 代替边界 authority。
短章节同时处于真实首尾时，由pointer pull方向选择上一/下一章，不以检查顺序固定优先下一章。
continuous current/progress 的普通interior仍由viewport center推导，但真实min/max scroll extent分别映射首/末页；
显式slider scrub anchor存在时selected page优先作为navigation identity，无scroll range时保留既有current。
这样短页章节的边界落点、slider与progress不再因center不可达而回退。
ScrollPosition 因 layout/ballistic correction 产生的通知 MAY 更新内部测量与 pipeline observation，但 MUST NOT 在 layout pass 中同步驱动 ValueNotifier/widget rebuild；应复用既有 post-frame observation owner。关闭跨章 UI 时不撤销任何相邻章节预加载。
跨章节预加载由 App composition 在当前 Reader route 生命周期内建立低优先级 `CompositionChapterPreloadLease`，直接挂到现有 `CompositionDownloadTransferRuntime` / `DownloadTransferOwner` / `NetLane`；
它延伸的是同一个稳定前 7 / 后 3 encoded window，而不是额外再加 7/3：先扣掉当前章按实际阅读顺序仍可覆盖的页数，只把残余水位补到下一章开头或上一章结尾；因此跨章后总逻辑窗口不扩张。adjacent claim priority 500 低于当前章 far window 的最低 520，
并继续受共享 `SpeculativeEncodedReadBudget`（默认 50MB）和既有 source bucket/concurrency 限制。页面推进时只更新同一 preload lease 的 demand 集，不因水位伸缩反复创建物理 transfer owner。它不得读取 `crossChapterReading`、不得创建第二个 scheduler、不得绕过 ArtifactCache/partial/physical-session authority。
真正跨章时先 flush 当前 Reader progress checkpoint，再通过 `HomeLibrarySession.upsertChapter` 确立目标章 durable identity，然后替换 prepared chapter；预加载本身不得因“只是预热”提前持久化未进入章节。相邻章 preparation 可在同一路由内合并并复用成功结果，但 null/error 必须从 coalescing cache 退役，使瞬时 source/plugin 失败可以在后续边界 pull 重试。
Reader邻章目录查询先筛当前source，再按本次调用的canonical authority限定当前comic family，复用原catalog/alias投影；raw代表身份、entry/progress引用与logical排序保持原边界。
canonical memo仅活在单次查询；后续调用重新读取source authority和目录，Home全库projection不变，不新增Reader状态或持久cache（ADR0381）。
`reader_runtime` 在页码/阅读模式改变时通过既有 progress facade 提交最新 checkpoint。
SQLite 实现使用独立 progress isolate/WAL connection；
Reader 热路径只将 checkpoint 有序入队，不执行同步 sqlite3、章节 JSON 解码或 `HomeLibrarySession` 发布。
writer尚未ready/启动失败时persistent store只保留每章latest checkpoint并以有界backoff重试writer，
只有route/lifecycle flush或close durability barrier允许同步fallback。
每个 Reader route 只在 composition 内持有自己的 latest progress；
正常route pop前先drain Reader-local writer并等待storage-owned durable flush；失败可记录后退出。route返回后只把最终progress发布到 `HomeLibrarySession` 一次，不再等待额外barrier或reload library/history。
磁盘完成不得成为普通翻页的前置条件；最终退出barrier不扩散到逐页checkpoint（ADR0303）。
`HomeLibrarySession` 同时记录 library projection revision；
reload 在开始阶段捕获的 entries/SavedComic snapshot如果在 enrichment期间已被 write-through mutation超越，
结束时不得覆盖更新后的 mounted projection，download snapshot也必须基于最终可见 entries。
inactive/paused/detached 继续主动入队最终 checkpoint，进程被系统直接终止只提供 best effort。

## 5. 页面角色、窗口与优先级
- Reader route 进入 `inactive/hidden/paused/detached` 后，用户播放状态不变，但 Pipeline playback MUST 临时视为 paused；
  `resumed` 后按用户原 `paused/speed` 恢复。
  后台不得继续 Animated WebP decode/upload/present，也不得用 worker 重建、CPU affinity 或 raster 降质掩盖生命周期问题；
  current 具有最高资源优先级，但目标页首帧不得依赖 current 的下载完成或 holder 深度。
- Reader route 覆盖 Home 期间，`HomeLibrarySession`仍可更新并持久化 progress、
  version relation 等非 carrier authority，但隐藏 Home MUST NOT 因后台 publication 整树 rebuild；
  首帧后的 metadata/version source snapshot 本身不得持久化 `pages[]` carrier，route 返回后只统一刷新实际发生过的 Home publication。
  App 根部的 theme shell 只观察 `AppPreferencesController.themeChanges`（当前仅 `themeMode/amoledDarkTheme`）；
  总 preference `ChangeNotifier` 继续服务设置页、Home 的字段级过滤与持久化，
  但 comic Reader/adaptive-profile 写入不得失效 `MaterialApp` 或被 Reader 覆盖的 Home route。
  Reader 首个实际 presentation frame 后的 metadata/version refresh 必须真正异步调度，
  不能在 first-frame callback 栈中同步执行到第一个 await，也不得成为 current page source-plan 的前置门槛。播放专属控件的可见性只能来自真实媒体能力证据：
  manifest/后缀/`animatedHint` 只允许作为预取或分类提示，不能让 pause/speed 先验显示。unknown 默认隐藏；
  codec/decoder 观察到至少两个实际帧即可立即确认 animated，完整静态证据才确认 static。
  Venera source semantic retry 的“单次恢复链”与“用户显式新一轮下载”属于不同 generation：
  同一 generation 内 `onLoadFailed` replacement 仍有有界上限（当前 5），普通 provider/network retry 不得重置；
  当 semantic media rejection 后 source-owned `retryResource/onLoadFailed` 已无 replacement plan 时，
  `SourceResourceTransport` MAY 在同一 NetLane task、同一 `TaskControl`、
  同一 logical open 内对相同 opaque locator 做且仅做一次 fresh request-plan `resolveResource` re-resolution；
  该步骤不得重置 replacement budget、不得创建 Reader/UI retry owner，
  若 re-resolved plan 仍 semantic reject 才升级为 `recoveryUnavailable` 供 App stale-carrier refresh；
  仅当章节命令最终以 `ErrorCode.source` 失败且用户显式 retry 时，才可针对实际失败的 source-owned locator 开启 fresh resource generation。
  若旧任务跨进程/版本恢复后只剩 failed chapter state、内存 locator 集已消失，
  则同一次显式 Retry 可先按旧 generation 运行到第一个重新确认的 source-terminal locator，立即只 fresh 该 locator，并允许该用户命令继续一次；
  不得刷新未触达页，也不得让同一 locator 在一次 Retry 内反复 fresh。
  fresh generation 必须同时失效 host request-plan 与 Venera retained config/resolution，再重新执行初始 `onImageLoad`。
  Mihon source-owned resource replay 使用同一 transport owner、但采用更窄的一次性 contract：
  新生成的 Mihon opaque page locator 都携带稳定 `chapterId + pageIndex` replay 坐标。host-direct request plan 另外携带显式 `directPlanReplay` capability，
  因此过期签名 URL/旧 page plan 在 host transport 失败后可沿既有 `SourceResourceTransport.retryResource` 一次性重新读取 chapter/page list；
  这不创建第二个网络 retry owner。runtime-transform locator 仍绑定 `mihon-runtime-transform-v3:<payload-sha256>`，且 runtime-owned `loadResource`
  发生**非网络、非 verification** source failure 时，driver 才发布 `sourceResourcePlanReplayEligible`，并允许一次 `retryResource`
  重新读取 chapter/page list。普通 SSL/EOF 不获得该资格，继续由 DownloadJob 的既有 network retry owner处理。
  宿主沿实际异常链识别连接、socket/DNS、TLS与正文I/O失败；最深层native syscall/certificate原因不得掩盖外层具体transport异常。
  default-client把source/parser错误包装成普通`IOException`时仍按真正来源原因分类；`UnknownServiceException`保持非网络语义，不扩大replay或retry owner。
  若一次 replay 无 replacement plan、replay 本身发生 source failure，或 replacement 再次出现同类 replay-eligible failure，
  transport 不再递归 replay，而发布 `sourceResourcePlanReplayUnavailable`，再交给既有 terminal source-generation refresh handoff：
  Reader 当前页、章节下载命令、whole-comic queue 只在各自 owner 内各做一次整章刷新；不得在 Reader/Pipeline 增加 Mihon-specific retry loop。
  显式新 generation 的 `refreshResource` 与上述 same-attempt replay 分离：adapter 发送 `freshGeneration=true`，Mihon runtime
  重新读取 chapter/page list，并按 `sourceId + locator` 在当前 runtime generation 内有界保留 fresh **source request authority**，供后续 resolve/re-resolve 与 runtime-owned `loadResource` 共用。
  same-attempt replay 也必须把 fresh page/request authority 一次性传到紧随其后的 runtime load；不能只把 replacement `requestPlan` 返回给 Dart，随后又从原 opaque locator 重建旧请求。
  runtime load 仍由 source 自身 client 执行，method/headers/body/cookie/interceptor 语义不得降级到通用 HTTP client；ordinary replay authority 消费一次即清，fresh generation authority 则保留到 generation 失效。
  升级前已经持久化且缺少 chapter/page replay 坐标的 `mihon:resource:` locator 必须在 App composition 的既有 source-locator compatibility gate
  被识别为 legacy，并在 Reader/下载消费前强制 source refresh；不得为这次 locator-schema 补全而全局改写 `sourceRevision` 或制造额外漫画版本。
  source setting mutation 推进 transport generation 时，driver 必须同步失效该 source 的 retained fresh/replay state。
  旧 v1/v2 locator 在 Reader/下载入口必须先强制 source refresh 到 v3；v3 transport revision 绑定已验证 extension payload SHA-256，
  当前安装 payload 与 persisted revision 不一致时同样必须 refresh，不能让插件升级前的 opaque request plan 继续冒充 durable current authority。
  payload 比较只适用于 revision 末尾携带完整 v3 SHA-256 authority 的 runtime-transform carrier；
  普通 HTTP/replay-capable Mihon 章节不因已安装插件具有 payload authority 而强制刷新。
  Reader、下载与 version preparation 共用同一 compatibility gate，legacy locator 和 snapshot placeholder 检查保持独立。
  Download Manager 自动缓存消费 durable management projection，而非把 exact `CacheRec` 当唯一存在性 authority。
  compact Home projection 只提供 chapter identity/pageCount，
  management cache/snapshot 不得把 `zic-home-snapshot-page:*` placeholder 展开成 `DownloadId`；
  exact READY/partial 必须按 durable chapter inventory 聚合，
  canonical 行仍只由 canonical physical inventory/projection proof 建立，禁止为了展示缓存猜 page index。
  已知 library chapter 的 canonical `physical_media_artifact` / physical partial 必须按 canonical projection 直接计入完成页、
  字节和 partial 进度，即使当前版本没有 exact READY row；exact binding 只决定 exact/pinned/manual 属性。
  Reader/后台 durable mutation 只发布轻量 management invalidation；UI 防抖 single-flight 重读。
  显式 chapter run 期间 invalidation 只记 dirty，最后一个 run 结束后合并补发一次，禁止逐页全库重扫，也禁止吞掉并发 Reader cache 变化。
  管理投影表示 durable physical inventory，不等同于 runtime reuse 授权：
  已物化 canonical physical object 即使当前 relation proof 后来撤销仍可显示为缓存事实，
  但新的 exact runtime claim 仍必须通过 active `CanonicalMediaChapterAuthority`；
  同一页同时存在 canonical/stable 物理事实时管理投影优先 canonical 实体。
  同一 `PhysicalMediaId` 暂时同时存在 READY 与 stale partial 时，所有只读管理/usage projection 必须立即以 READY 为唯一可见 inventory：
  partial 不再贡献 page state、bytes、entry count 或 trim pressure；投影本身不得因此执行删除。
  显式 clear 仍可由 persistent maintenance 顺带删除该冗余正文，但不能把它计成第二个 cache eviction。
  全局 clear/trim 删除 canonical physical binding 前由 SQLite 在同一 `BEGIN IMMEDIATE` 事务内复核 physical LRU generation 与 surviving exact READY 引用，
  避免 busy/pinned/new exact race 拆掉 canonical routing。
纵向 `ListView` 的 steady-state composition `cacheExtent` 固定为 2 个 viewport 高度；
首次布局只允许一次有界 6 屏组成，首个 scroll end 后收回到 2 屏。它只保留 page shell/element 组成窗口，不改变 encoded/decode/upload/texture 需求窗口。
该窗口不得通过 idle post-frame 渐增 warmup 扩张，避免在下一次手势前触发大范围 sliver rebuild。
Reader 的 `readerFrameTiming` 诊断在源头只按约1秒聚合真正普通帧并保留样本数及build/raster/span/vsync/frame-interval min/max；
达到16.667ms build/raster/span预算或frame interval>=20ms的异常样本均逐条写入并切断摘要，
独立scroll/platform cadence observer只补充归因，不能替代异常帧原始时序。
原始vertical ScrollUpdate若非零位移且相邻通知间隔>20ms MAY记录`scrollCadenceOutlier`；
该事件只用于区分ScrollActivity/input cadence与render missed-vsync，不得请求debug frame或成为滚动/pipeline输入。
`ScrollUpdateNotification.dragDetails`存在时Reader MUST保留`Interaction.dragging`并在`scrollCadenceOutlier`记录`dragDriven=true`。
dev.310的ballistic证据继续否证“touch sampling解释post-lift cadence hole”这一宽泛假设；ADR 0325只以healthy-cadence逐帧位移重新打开finger-down drag边界。
`reader_runtime`在vertical continuous Reader生命周期持ref-counted `GestureBinding.resamplingEnabled` lease并最终恢复原值；`reader`不得拥有该framework state。
`samplingOffset`、合成位置、自定义Ticker/forced frame与ScrollPhysics调参仍禁止，ballistic cadence仍独立归因。
Android platform cadence归因由`reader_runtime`的`android.view.Choreographer` observer拥有：
仅显式`ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true`诊断构建的vertical Reader生命周期启用；
默认不订阅逐vsync callback、Window metrics listener或2s drain，避免静态页被观测本身持续唤醒，被动Flutter timing/任务Trace不受影响。
启用时native把>=20ms frame/callback gap或>=8ms callback lag写入bounded 256 ring并附main-thread CPU delta/display refresh，
同时对所有native frame interval做低成本固定bin聚合，Dart最多每2s低频drain成`platformFrameCadenceOutlier`与`platformFrameCadenceSummary`；
两类事件均不得请求Flutter frame或驱动Reader/Pipeline。
dev.312独立ARR policy A/B已由dev.313跨设备证据排除为共同根因，production Reader不得继续自动激活该行为干预；历史adapter仅保留复核能力。
Android Window `FrameMetrics`只作为Window/ViewRoot补充诊断：
API24+由独立`zic-reader-window-metrics` HandlerThread采集total/unknown delay/input/animation/layout/draw/sync/command-issue/swap，
API26+另采intended/actual vsync；
同一vsync callback必须去重，summary记录first/last vsync以显化覆盖范围，`droppedReports`仅表示metrics report loss。
它不得被假定为Flutter `SurfaceView`内容帧的连续代理。
离线Perfetto验收必须分别核对本次buffer/parser完整性与ZIC内容层覆盖；`traced_buf_chunks_discarded`表示本次buffer丢弃，
service lifetime的`traced_chunks_discarded`不能单独判定本次trace失效。缺少SurfaceView FrameTimeline时，
同次输入/Reader motion关联的精确内容层`SurfaceFlinger --latency`只能证明该采样窗口的呈现cadence，不能替代composition/触摸延迟或视觉验收。
仅显式`ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true`的诊断构建允许vertical active scroll在每个实际Flutter post-frame读取live `ScrollPosition.pixels`与current page RenderBox globalTop，
并用`globalTop + pixels - expectedStart`形成跨页不变量；
只聚合`verticalSceneMotionSummary`与有界outlier，不调用scheduleFrame/setState/position mutation；普通构建不得注册该scene-motion矩阵采样probe。
cacheExtent/`current±7` keepAlive 只拥有 composition residency，不等于 UI animation admission：
`ReaderView` 必须用同一 vertical geometry 的 `visibleCoverages` 投影 `visibleMin..visibleMax`，
对仍挂载但实际 viewport 外的 page subtree 关闭 `TickerMode`；
其 async source/cache/decode/presentation preparation 继续推进，重新进入可见范围时恢复 ticker。
不得用 current-only、Pipeline role、download state 或删掉 loading feedback 来替代该可见性边界；paged Reader 不受此 gate 影响。

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
  local/remote bucket limit 始终来自 `ReaderPipelineProfile`，不得以首帧/output readiness 临时改写；
- current priority 1000；
  network/decode/upload 各保留 1 个仅 current 可用的高优先级 handoff slot，transition priority 900 不占该保留槽；
- network `NetLane`以normal=5、current-only reserved=1为单一物理调度边界：
  normal priority 780/800/820/900只参与排队与active rank迁移，不得为了normal-slot pressure主动取消receiving task；
  current=1000在5个normal槽已满时先直接借第6个reserved槽，不得把“借handoff”本身实现为先cancel victim。
  只有normal+reserved均真实饱和且current持续blocked时，才允许统一`NetPolicyRank`按40分margin选择victim；
  破坏性preemption还必须满足NetLane-owned incoming candidate stability，Reader当前为100ms，free/reserved admission不受该等待影响。
  每个NetLane同一时刻最多一个preemption victim处于已cancel但未物理退出状态，
  其他blocked current继续排队/更新rank，victim真实退出后再pump，禁止一个scrub burst并行扩大取消面。
  logical claim归零的already-admitted task仍迁移rank0并标记`demanded=false`，queued未admit可直接移除；
  normal transport lease不足时优先回收这种inactive parked task；
  仍`demanded=true`的parked窗口成员只有在新的incoming按同一`NetPolicyRank`+40分margin明确胜出时才可被`ranked-transport-lease-reclaim`，
  从而避免低rank parked response把next/next2永久锁在队列里。consumer-bound transport真实dispose/错误/显式用户终止仍是独立硬取消边界。
  Venera单JavaScript request-plan permit继续独立使用controlled floor=780与current动态preemption，
  因为它保护的是单context invocation而非最终图片HTTP槽；gate同时观察waiter promotion与active current-class demotion，
  旧current降级且已有新current等待时重新执行同一40分preemption判定，普通非current demotion不触发取消；
  旧JavaScript必须真实`finished(requestId)`后才能转交permit。
- DownloadJob 不读取 holder depth、播放状态或页面控件；远端下载窗口、decode/upload execution reservation 与播放水位分别由唯一 owner 管理。

## 6. Decode 水位与 Transition 首帧
- Reader/Pipeline 控制词表不得靠跨包裸字符串或重复阈值维持一致：
  decode refill 只产生共享 `DecodeWaterlineStage`，该 stage 只描述 DecodeSession refill，
  不得反馈成 encoded/network admission、另一页面的 body-flow credit 或 memory-pressure network gate。
  Animated WebP 的 physical-task frame credit 只随**同一页面自己的 role**变化：
  current/可见 transition unlimited，next/next2/previous 为 5/3/2，稳定 3/7 envelope 内更远页为 1；
  较近页下载慢、holder depth 不足或 decode waterline 卡住都不得阻塞更远页已有 DownloadDemand 的 transfer。
  跨页 encoded 压力只由 `NetLane`、source bucket 与共享 actual-read budget 裁决。
  0.15 transition/overlap 与 0.5 dominant coverage 使用共享常量，
  Reader latest-wins gate 的 transition 边界直接读取当前 `RoleResolver.transitionThreshold`。
  URI 后缀只作为容器 evidence，由 Pipeline 统一暴露 WebP/known-non-WebP 判定，
  `.jpe/.heic` 等已知静态后缀不得在 runtime 被重新当成 unresolved WebP 去预建 native output。
  用户 pause/speed 的跨 generation 默认只由 `UploadRegistry` 保留，
  具体 `UploadSession` 只保存自身 user-pause + viewport-freeze 合成状态；`PipelineReaderSession` 不得持第三份 pause 镜像。
  `HomeLibrarySession.dispose()` 只停止 Flutter 通知，不能代替 owned resource teardown；
  `close()` 必须 single-flight 并在 dispose 之后仍能真正关闭 library/chapter/whole-comic owners。
  Home 的 download-composition capability 也只在 `HomeLibrarySession.resolveDownloadComposition` 正规化一次：
  显式 composition 优先，否则才消费 chapter service 自带 provider；
  bootstrap、handoff 与 cache binding 只复用该结果规则，不能各自复制 provider cast。
  长生命周期 Settings route 同样不得捕获 `WholeComicDownloadQueue`、
  `ResourceCacheCoordinator`、storage root 或 chapter-download relay 的 generation-bound 对象；
  policy/data settings 只能持 generation-following capability binding。
  cache usage inspect 可以等待已经发布的 adoption，但不得仅因查看设置而强制创建 durable core；
  clear/trim 属于显式 durable mutation，必须先确保并采用 current core generation，并在一次操作内固定同一 coordinator。
  chapter-download relay 的 capability identity 变化也必须通过 handoff change signal 发布，使已打开的 Data Settings 立即更新可用性。
  Whole-comic policy 设置同样不得捕获某一代 `WholeComicDownloadQueue`：
  读取只经 `HomeLibrarySession.downloadProjectionChanges + wholeComicQueueSnapshot`，
  写入只经 `HomeDownloadCommands.updateWholeComicPolicy`，
  因此设置 route 在 durable handoff/service replacement 后继续跟随当前 generation。
  用户显式 library backup 也不得由 Settings/UI 逐 section 拼装可穿插的 store 读取：
  当前 generation 的 library owner 通过 `ImportedLibraryBackupSnapshotStore` 提供一次 semantic snapshot；
  SQLite 在先 flush Reader checkpoint 后，以一个无 await 穿插的 read transaction 同时读取 chapter/progress、
  SavedComic、分类、偏好、已读、source preference 与 migration issue，Memory/Lazy 保持同一语义；
  Lazy 的显式 backup 属于 library durability action，必须先 single-flight materialize/merge durable library，
  避免已有磁盘数据在 bootstrap handoff 窗口被 memory projection 遮蔽。
  Android备份通过App的document-export channel提交JSON bytes/MIME到既有单一OS文档创建操作；与Trace共用平台pending-result生命周期，备份不依赖Trace log或目标目录。
  平台只写所选document并回传URI或取消；library snapshot/进度flush仍归library，备份失败单独显示诊断，不写入缓存统计失败状态。
  长生命周期 `LibraryDiagnosticsScreen` 同样不得冻结 route-open 时的 `ImportedLibraryStore`：
  Home 只注入动态 current-store resolver，并监听 `HomeLibrarySession.libraryGenerationChanges` 这一窄 generation signal；
  refresh/copy/ack 在完成前必须重验 store generation/identity；
  切代中的旧 read 必须转到当前 library，ack 只能用 schema/entity/legacy key/resolved source/details/createdAt 组成的 semantic issue identity 在新 store 重新定位其 local `issueId`，
  绝不能跨 store 重放数值 `issueId`；普通 Home projection/download publication 不得触发 migration diagnostics 重读。
  持续打开的 Local/Remote Comic Details 也不得订阅 route-open `ChapterDownloadService.changes` 作为 Home live authority：
  Home 只注入 `HomeLibrarySession.downloadProjectionChanges` 这一 generation-neutral projection signal，
  signal 到达后由既有 `HomeDownloadCommands` bulk-inspect 当前 generation；
  跨 signal 的 in-flight inspect 结果必须按 projection revision 丢弃，
  且 current-generation `idle` 有权清除旧 generation 的 active 状态。standalone/widget 构造可保留 direct stream fallback。
- 前台 current Animated WebP 的 decode raster MAY 由 `PipelineReaderSession` 内部的 measured-throughput governor 临时降档，
  但唯一输入必须是该动画实际 `nativeDecodeMicros` 与自身 frame cadence，不得读取 power-save/cpuset/CPU affinity 作为策略事实。
  full raster 连续超预算后允许降到2/3，若 lower raster 仍连续超预算可继续单向降到1/2；
  降档在同一 Reader session 的 animated/未决相邻页间保留，避免每页重复支付 full-raster 慢帧。
  恢复 full 必须先在降档态连续证明明显快于 cadence，再只于后续 page boundary 执行；当前页确认 static 可直接恢复。
  Reader route detach/re-attach 重置该瞬时性能状态。
  该策略只改变 DecodeTarget/presentation pixel carrier，不得改变 source geometry、
  3/7 download window、decode waterline、网络/缓存 authority 或用户 playback state。

动态页面的 role 最大 holder 深度为：

```text
current / logical next / next2 / previous = 7 / 5 / 3 / 2
```

current 的浅水位 bootstrap 优先于 speculative neighbor：动态 current depth < 3 时，next/next2/previous 的实际 refill 目标暂为 0；
静态 current 只需 1 帧；其 source 暂不可执行时，既有 `targetWatermark=1` 邻页可按 priority 独立完成首帧，仍服从统一 presentation grant 上限。

```text
current depth < min(3, role max) -> current bootstrap；current 等 source 时，真实 viewport transition 可执行 `t>0` 独立取得 1 帧
```

bootstrap 完成后恢复 staged refill：

```text
n>1, m>1, p>1, c>4, n>2, c>6, n>3, m>2, n>4（current bootstrap 已覆盖 c>2）
```

阈值仍是严格水位，实际 batch 可自然越过。current/source 尚未建立浅水位时不得让 speculative neighbor 绕行多帧 refill；
真实 transition 只在 current 暂时无 source 资格时可取一帧；等待单帧 current 的静态邻页仅消费已有 one-frame intent，不要求新的 Reader observation。
静态页一帧即满足；
positive static evidence MAY在稳定 encoded previous3/next7 envelope 内建立 `targetWatermark=1` 的 DecodeDemand/UploadDemand，
但这些只是 one-frame intent，真正执行由 `StagedDecodeRefillPolicy` 按 priority 一次释放一个尚未满足的 speculative static presentation，
不得恢复固定 current/+2/-1 static gate 或 estimated-output-byte admission。static-warm资格必须来自正向静态证据：
`runtimeAnimatedPages[index] == false` 的decoder truth、
JPEG/PNG/AVIF等明确静态`ContentKindHint`/后缀，或同章至少两页authoritative static且尚无authoritative animation时的既有chapter-level unresolved-static inference；
`animatedHint=false`只是缺省值，opaque unknown、WebP/GIF hint与`.webp` URI在未分类前都不得据此当作static。
physical ingress已投影page-local `runtime WebP cost`时，
该页即使chapter-level static inference成立也 MUST继续等待自身decoder classification，
不得通过static-warm/visible-static旁路横向0.15 transition presentation门；
decoder后续确认static后恢复既有warming，current/transition primary UploadDemand不受此限制。
native decoded/upload residency继续由`FrameBudgeter`裁决，
external Flutter fallback raster由App composition的`ImageCache`裁决。
encoded previous3/next7同时是逻辑/retention与DownloadDemand窗口，动画不得再缩成2/4；
动画/未决WebP只附加task-local response-body frame credit：current/可见transition无限流，next/next2/previous为5/3/2，
其余远端为1，credit只随同页role变化，decode waterline不得反馈成另一页的network/body-flow gate。
`WebpFramePrefixTracker.completedFrames`仅是ANMF encoded结构进度；
DecodeSession唯一产出playable-prefix evidence并generation-aware投影到DownloadSession。
正target只有structural count与decoder playable-prefix floor同时满足才可park。dev.268起，park不再结束transport attempt：
`DownloadJob` flush authoritative pending bytes后保留同一ByteResponse/StreamIterator，调用NetLane释放body-read permit；
`active`只计持permit任务，`running`记录physical task，`globalDemandedParkedResponses/globalInactiveParkedResponses`分别记录仍有demand与inactive的live response retention。
demand/target/floor变化后同一task重新竞争permit并原地继续，Range capability只影响真实eviction后的resume方式，不再决定水位满足时是否主动关闭response。
demanded flow parking仍默认保留live response；但真实transport lease饱和且incoming的统一scheduler rank明确高于parked response时，
NetLane可`ranked-transport-lease-reclaim`该较低rank retained response，restart-cost足够高时仍保留。
`demanded=false`且保留live response的task继续占transport lease，
但在新的demanded work被真实lease饱和阻塞时优先`inactive-transport-lease-reclaim`。
不存在第二个inactive parked数量cap，Reader 3/7不拥有response/socket容量。
artifact-cache durable body以`responseRetained=false`同时释放network read permit与transport lease，
其本地body读取只归`ArtifactCacheReadScheduler`。
`consumerPacing`不承诺native upstream完全停收，因此live HTTP/source response必须由transport lease有界；
不得恢复每100ms pseudo drain、`DownloadFlowSuspended`、`retainFlowResponse`或normal `inactive-reclaim`。
physical frame proof由DownloadSession generation owner保存，target0/current始终表示网络需要继续。
sealed source expected-length幂等、artifact-cache/resident bypass、
normal5+current-reserved1保持不变，并分别约束transport/source lease与body-read permit；
`running` physical task可因local artifact work高于该值，但live source/socket不得绕过transport lease上限。

纵向Reader的页面比例事实仍只由`reader_runtime`投影为`pageAspectRatios`，`ReaderView`是滚动期间采用哪一版几何的唯一owner。
尺寸到达时机可由DecodeSession首个成功frame的`decodedWidth/decodedHeight`触发，
但页面几何的最终authority必须是**source canvas**，不是decoder为target生成的对齐/下采样**decoded raster**：
Pipeline通过框架无关的只读`PipelinePageDimensionsFeed`发布`pageIndex + assetKey + width/height + basis`，
优先使用`PageAsset`固有尺寸或当前artifact的WebP source canvas；
仅在source canvas尚不可得时允许`decodedRaster` provisional fallback，且source一旦存在不得被raster降级覆盖。
`parseWebpPrefixInfo()`对VP8X/VP8/VP8L只需固定header即可读canvas，不等待整个compressed image chunk。
LocalImagePlayer的output/surface raster只属于presentation，不得经`onDimensionsChanged`反向污染Reader geometry。
该feed只允许订阅/退订并在attach时重放retained facts，publish/clear保持Pipeline library-private；
公共边界不得暴露Flutter `ValueNotifier`/`ValueListenable`。
一次finger-owned drag/ballistic/settling期间，`ReaderVerticalGeometry`与`ListView.itemExtentBuilder`继续绑定scroll-stable layout snapshot；
真实visible页的新ratio只做latest-wins pending；forward方向严格位于真实visible tail之后的future页可提前采用，reverse incoming prefix可按提交前top-pixel anchor在同一次layout原子补偿。
slider scrub不属于该冻结边界：当前已visible页的authoritative source ratio MAY立即提交，并以slider-selected current为center anchor做layout-time correction后重发visible coverage；
否则unknown ratio的一屏provisional extent会让相邻已挂载页永远无法成为visible，从而与transientPreview的hidden decode/upload gate形成闭环。
active物理观察继续消费ListView已采用的immutable geometry；Reader保留最新有效motion pixels，仅按private ScrollPhysics实际layout校正移位；前后pixels在同一applied geometry计速。layout重发coverage与倒退输入不推进有效physical sample或采样时钟。
raw pointer跨过touch slop只推进interaction并观察coverage，不推进运动采样时钟；同一输入的ScrollUpdate才采样真实位移。
真实drag直接采样并退休更早的合并采样请求，ballistic ScrollUpdate通过同一post-frame observer采样；idle/scrub保持零速度，controller/composition更换清掉待采样fact。
连续drag有递增source pointer时间时以同域输入间隔计速；首个/缺失/相等时间与ballistic保持Reader回调间隔，绝不跨域相减。倒退时间只刷新physical coverage/position，保留最新有效motion baseline/velocity；layout/phase不推进baseline，scroll start/idle/scrub/controller更换或真实非source采样退休旧时间。
实测速度outlier只稀疏记录采样入口、前后位置、实际采样与回调间隔，诊断事件不得参与navigation、geometry或Pipeline policy。
进入idle后其余pending ratio仍由top-pixel layout correction一次提交；prefix补偿保留准备时pixels，首次layout叠加期间真实motion并跨重复layout幂等。新drag保留该未完成补偿，frame timing只读预览，frame末退休；slider/tail绝对导航仍按既有规则退休。
不得恢复dev.286的独立visual presentation extent/OverflowBox裁切workaround，也不得以扩大decode 2/1替代geometry authority修复；
Pipeline dimension metadata不得参与download/decode/upload admission。
dev.294起，纵排抖动诊断的`pageLayoutSnapshot`只在Reader debug Trace中低频采样真实可见RenderBox的constraints/size/global rect/transform，
并与expected extent、role、interaction关联；它是纯观测事实，不得反向驱动geometry、navigation、Pipeline或texture策略。
dev.300起Flutter engine的`SchedulerBinding`/`dart:ui FrameTiming`/`FramePhase`只允许存在于`reader_runtime` presentation adapter；
`reader`只消费框架无关`ReaderFrameTimingSource`投影的`ReaderFrameTimingSample`并关联自身scroll/current/interaction，
不得直接解析engine timing API。Pipeline的visual frame boundary同样不得由resource/projection core直接调用Flutter binding：
`PipelinePageOutputStream`的visual claim release与current transfer projection逐帧coalescing统一依赖框架无关`PipelineFrameScheduler`，
其`SchedulerBinding`实现只属于`pipeline_native` presentation adapter；
transfer UI公开边界使用只读`PipelineTransferProgressFeed`，不得暴露`ValueNotifier`/`ValueListenable`。
诊断 Trace 属于观测投影，也必须服从 UI isolate 帧预算。locator脱敏正则只初始化一次，普通字符串必须在scheme marker快路上跳过；
App DebugTrace的UI/export存储是O(1)头部淘汰的有界ring，coalescing bucket只能引用仍存活entry并随淘汰清理，
range合并只扫描当前事件实际携带的allowlisted数值字段。没有Trace viewer listener时记录不得请求Flutter frame。
PipelineReaderSession只把Reader-local事件写入显式注入的App sink，composition physical事件继续由ref-counted shared sink去重；
不得再创建无消费方、无上限的每Reader私有全量memory副本。测试/工具显式使用`MemoryTraceSink`时可选择有界容量。
Pipeline Android texture 的正常逐帧 `TexturePresentTelemetry` 不再额外投影为 `frameUploaded`：
完整 timing 仍保留在 `OutputFrame`，并由 startup/stall 的 `framePipelineTiming` 归因；
仅保留达到 20ms、deadline miss、surface reconfigure 或 fallback 的 platform 样本，
避免 MethodChannel 回调在 Flutter isolate 重复分配诊断 payload。
这些规则只约束诊断成本，不参与Reader observation、DemandPlan、lane、NetLane、geometry或presentation决策。
Native Animated WebP decode 可沿 `FrameNativeDecodeObservation` 投影 prepare/canvas/fragment/composite/frame-copy 分段、
实际OS thread id/CPU start-end/allowed mask及bounded frame-structure统计；
这些字段只用于区分codec成本、线程调度与canvas依赖，绝不得成为waterline、worker placement、DecodeTarget、transport或presentation策略输入。
`TraceEvent`构造边界同时承担payload JSON-safe归一化（Enum/Uri/Duration/DateTime/未知diagnostic对象均不得原样进入export ring）；
`scopeId/physicalMediaKey/providerExactId/candidatePhysicalKeys`中的长或opaque组合键按完整原值生成稳定hash/原长度摘要，候选列表与嵌套map共用此边界，重复归一化幂等；Telemetry不解析领域framing/provider payload，也不改变独立comicId脱敏或任何运行时identity/cache authority（ADR0384）。
导出UI只负责snapshot/编码/文件选择，不应成为类型修复owner。用户可见的Reader原始技术错误至少由Trace或复制操作保留完整诊断，章节route终局错误同时记录`taskFailed`并提供复制。

纵向 page shell 的 steady-state composition cache 固定为 2 个 viewport，首次布局的有界 6 屏 pass 只用于初始相邻 host 准备；
它只决定 sliver 中的页面宿主组成，不得扩大 Pipeline 的 encoded/decode/upload 窗口。
current±7 的 keepAlive center 在 active scroll 内继续冻结；
进入 idle 后若 current 已跨过较远距离，center 不再一次跳到 current，而按 Flutter frame 每次最多 3 页向目标收敛，
避免旧 ±7 host 在一个 frame 内集中 dispose。显式 navigation/direction change 仍可直接提交其目标 center；
该有界 recenter 不扩大 keepAlive 半径，也不改变资源窗口。
连续纵排中实际可见的静态输出通过 `UploadDemand.retainOutput` 表达，由 `FrameBudgeter` 与 current/transition/last 一并保护；
不可见的 speculative output 仍按普通优先级回收。

## 7. 下载、partial 与 source ingress
- Reader transfer progress 是只读 projection，不拥有下载。
  `DownloadSession` 将 durable `committedLength/totalLength` 与当前 attempt 的 `networkCursorLength/networkAttemptTotalLength` 分开；
  后者只在 response lifetime 内存在，`DownloadJob` 在 response open 后立即发布 response total，
  full-body prefix catch-up 未完成前也不得借此提升 durable resume/seal authority。显示只使用一条共享横向尺度：
  transport wave 覆盖 `0..networkCursorLength`；
  当 transport 仍落后于 authoritative partial 时，只在 `transport..committedLength` 画剩余 partial 直线，追平后 partial 不再单独可见。
  显示总长优先使用已恢复的 durable `totalLength`；
  若旧 WebP partial 未保存 total，则可从本地 generation prefix 的 RIFF header (`uint32le@4 + 8`) 立即得到 projection-only `localEncodedTotalLengthHint`；
  active response total 可作为本 attempt 的临时显示尺度。两种 hint 都不得写回 resume/seal/promotion/cache authority；
  真正无法本地得出总长时不得用固定短条、虚线或任意宽度伪造比例。
- Download demand是consumer claim，不是物理transfer ownership：
  应用级`PersistentDownloadComposition`持有唯一`CompositionDownloadTransferRuntime`，
  其`DownloadTransferOwner`按exact `DownloadId`唯一拥有registry/writer/network/retry/hot partial；
  生产 App 的 network capacity 只由 application-level `DownloadResourceCoordinator.networkLane` 构造并显式注入：
  `PipelineReaderSessionFactory.pageDownloadLane`、`PersistentDownloadComposition.open(transferNet:)` 与 `LiveCoordinator(net:)` 都不得以缺省 `NetLane(...)` 静默创建第二套 production scheduler；
  `LiveCoordinator` 绑定 external transfer consumer 时还必须校验注入 lane 与 physical owner lane object-identical。
  独立 `PersistentChapterDownloadService.open()` 仍是完整 standalone composition，
  可以自持 transfer runtime/lane，但不得与共享 Reader/download composition 并存成第二 physical owner；
  plugin-host网络按admission ownership分层：
  repository/install/update属于`ExternalPluginController`管理control-plane并由controller关闭时取消active client，
  browse/details/request-plan属于有界plugin runtime gate；
  只有Reader/download媒体正文属于NetLane data-plane，source-owned rhttp/OkHttp whole-body transform兼容路径也必须位于已admit的physical task内并继承同一`TaskControl`，
  不得因socket位于plugin进程而形成第二scheduler；同一queued/active task的policy revision只能原位迁移priority并保持task identity；
  runtime source/media evidence只有改变权威调度语义时才可提交新的plan revision，
  `expirationRevision`只属于liveness刷新、不得进入Demand scheduling diff或制造cancel/submit/follow。
  一个accepted `DemandPlan`在sessions控制面必须作为单一scheduler transaction提交：
  Net/Decode/Upload mutation先写最终权威state，各lane只在outer reconcile完成后pump；
  physical transfer owner也在单次`replaceDemands`末尾统一执行local-prepare pump与prepared-admission drain，
  避免一个page-boundary的多claim迁移重复扫描同一pending集合；纯existing-scope download priority迁移属于scheduling metadata，
  不得广播完整media/session snapshot唤醒PageStream/progress/retention。
  DownloadSession诊断Trace与DownloadSnapshot publication必须是两个独立ownership edge：`_recordTrace()`不得隐式发布snapshot；
  existing-scope priority、flow-control、read-permit、resume、
  source/rejection等纯诊断发布0次，只有真实snapshot字段或claim-count生命周期变化由其状态owner显式发布且一次mutation最多1次。
  Reader current/prefetch与显式chapter command只attach scoped `TransferDemand`，whole-comic只聚合chapter command。
  priority只表达竞争顺序，required completion独立表达必须最终完成，取消只撤销自身claim；
  logical claim归零时already-admitted physical task保持同一task key、迁移到rank 0并在NetLane标记`demanded=false`；
  working-set detach本身不得cancel。
  NetLane把physical `running`、transport/source `transportLeases`与body-read `active` permit分开：
  DownloadJob在下一安全read boundary释放body permit并park同一response/StreamIterator，
  但只要live source response仍保留就继续占transport lease；
  normal5+current reserved1同时界定这两种network resource，不能用parked response绕过真实source/socket并发。
  `demanded=true` flow-paused response保持transport lease，但不再是无条件normal victim豁免：
  真实transport lease饱和时，新的demanded task只有在统一`NetPolicyRank`（base priority + restart-cost retention）至少高出一个preemption margin时，
  才可typed `ranked-transport-lease-reclaim`较低rank parked response；持body-read permit或正在resume的response不进入此路径。
  `demanded=false` inactive parked response仍不受第二个数量cap管理，
  并在真实lease pressure下优先typed `inactive-transport-lease-reclaim`。
  无pressure时working-set detach后的opening/parked retention仍是同一physical task的合法保留；
  `NetTaskDiagnosticSnapshot`只读记录active/opening/inactive时长、
  response/read-permit/transport-lease与restart-cost事实，
  `DownloadTransferOwner`仅以`inactive-retention-enter/reattached`及既有eviction/preemption Trace投影，
  严禁这些诊断字段反向成为admission/retry/reclaim资格。current-only destructive preemption使用独立`TaskPreemptionSnapshot`，
  inactive transport retention eviction使用`TaskRetentionEvictionSnapshot`，两者single-flight互不锁死。
  live current response的read-permit reacquire优先于新high-priority pending destructive admission；
  真实failure/provider dispose仍可结束response，DownloadState、Range、Reader距离不得形成第二套detach/reclaim策略；
  尚未admit的queued task可直接移除。native `Ingress`、decode/upload/presentation保持Reader-local。
  physical session只声明transfer/residency：普通hot/partial从session artifact重放；
  `residentBodyBacked`表示正文由外部immutable authority重放而非session artifact副本，绝不等价于durable cache ownership。
  physical generation另保留最多64-byte的generation-local source-metadata prefix并投影`sourceCanvasWidth/sourceCanvasHeight`；
  该prefix只属于encoded ingress metadata，不是正文副本。对JPEG等SOF可能位于APP/EXIF之后的格式，physical owner可在尺寸尚未知时另外保留最多64KiB的一次性dimension probe；它只用于尽早解析source canvas，尺寸成功后立即释放，不扩大64-byte metadata ABI、不得投影为正文缓存或第二份body authority。
  对已由persistent owner完成sealed/exact-length/provider preflight的immutable generation，composition还可持有两种纯加速事实：
  `ArtifactCacheManager`按opaque sealed physical-generation key保留bounded decoder bootstrap prefix；
  `ResidentReplayReaderPool`按同一key保留最多16个idle、已验证bound range-reader/descriptor作为hot-session之外的一层second-chance。
  二者都不得建立durable/body authority、不得跳过persistent/provider proof；
  `DownloadSession`只租用opaque key/reader lease，session reset/retention eviction必须归还lease而不是等价关闭底层descriptor，
  generation的physical id/length/checksum algorithm/checksum任一变化都必须miss，
  range read失败必须退休对应descriptor，composition dispose最终关闭pool。
  任何Pipeline/Reader source metadata读取必须消费这一physical ingress事实，
  `residentBodyBacked` session不得因其`Artifact`为空而绕过真实artifact-cache/source body authority。
  `ByteResponseBodyAuthority`显式区分source与`ArtifactCacheManager` body authority；
  artifact-cache durable body确认authority后必须释放NetLane network body-read permit，
  后续本地body带宽只由`ArtifactCacheReadScheduler`拥有；
  source-resident promotion不会自动持久化，显式durable completion才通过composition consumer/source authority校验length/validators并materialize到唯一ArtifactCacheManager/store。
  promoted session 的 active presentation read 若与同 exact identity 的 durable handoff 交叠，必须先消费当前 generation 已发布的 exact promoted hot projection；
  该 projection 在 persistent store commit 前保持 `durable=false`，只能作为已持有 DownloadSession 的 presentation 加速，不能升级为 durable/cache-management authority。
  只有当前 generation 没有 exact hot bytes 时，active consumer 才等待 mutation barrier 并重新选择 authority；consumer 自身 TaskControl/MediaLoadToken 取消仍是终局。
  任何已有active PageStream的页面在transport kind暂为null/unknown时都只等待Pipeline authoritative classification，
  不得因manifest/文件名同样unknown而让LocalImagePlayer并行启动loadBytes整页物化；WebP分类后继续streaming native output；
  明确gif/fallback分类只证明external presentation capability，
  仍必须等Pipeline staged refill向该exact DecodeId投影`externalPresentationRequested`后才可启动整页读取，分类本身不得成为UI load gate。
  sealed persistent artifact的普通stream read只做locator/existence/exact-length preflight并消费既有seal proof，
  不得在每次Reader访问重算whole-file CRC；
  exact/physical READY foreground open 的 LRU/recency `touch` 只属于 maintenance metadata，
  正文/descriptor authority 已成立后 MUST 立即返回给 presentation，
  recency 写入由既有 `StorageWriteScheduler` 合并异步提交，禁止让SQLite write pressure重新阻塞 `presentation-file-lease`；
  public显式exact artifact失效以正文authority复核，不把maintenance touch当作新代际；其余record比较仍包含recency，trim/eviction/adoption及内部read快照保护保持原边界。
  只有明确full `readAll`验证路径才可声明本次`crc32Verified`。full-read按物理replica逐个重算artifact CRC32：同长度checksum不一致属于结构性`checksumMismatch`，只退休坏replica并继续尝试其他sealed copy；普通stream仍不增加whole-file hash。
  `PageAsset.checksum`始终是来源声明的算法命名空间事实，即便声明`crc32`也只有在artifact owner对sealed本地bytes独立计算一致CRC后才成为durable artifact proof。
  `ArtifactCacheStreamEntry`必须显式携带stream/full-read integrity basis，
  joined read继承真正source operation的basis，`sourceRead` trace必须记录`artifactIntegrityBasis`与`artifactWholeChecksumVerifiedThisRead`，
  该观测不得反向影响cache admission/retry。Reader-local encoded source的生命周期由media plan拥有：
  宽7/3 DownloadDemand只建立/保持physical transfer，不得因此eager attach Reader ingress；
  DecodeDemand/UploadDemand或UploadRegistry批准的retained static output存在时才保留对应source generation，
  三者均不存在时必须释放upload/decode/native cursor/Ingress/SourcePool。
  late projection replay只使用通用bounded priority queue，不得按1000/780阈值或memory pressure重造PageRole eligibility；
  当高priority demanded Reader entry仍source-less且physical local prepare尚处idle、
  可能随后发布本地authority时，低rank replay不得提前占满全部bounded replay slots：
  registry最多保留1个现有slot给该更高rank pending source，session离开idle/进入network或authority到达时立即重新pump；
  该reservation只复用既有numeric priority与总capacity，不扩大并发、不创建PageRole/current专属gate；
  late projection replay继续从cache或可重开source提供encoded bytes并服从共享artifact-read scheduler；
  跨composition/runtime边界只允许未绑定`DownloadResidentReplaySource(session,end)`，
  进入具体physical generation前必须一次性绑定成`DownloadResidentReplayChunks(end)`；
  resident body backend选择属于`CompositionDownloadTransferRuntime`，Pipeline不得自行lookup cache/open source；
  异步late replay默认在追平authoritative committed boundary前保持source unpublished；
  但对已sniff为WebP的nonresident hot partial/Promoted产物，新Reader一律先从当前physical body重放自己的source-appropriate最小decoder probe（remote默认256KiB）并立即发布，
  让该Reader自己的decoder实时判断playable/need-more-data；
  完整source-resident immutable body若已seal且composition能证明artifact-cache或`file/content/asset` exact-range replay authority，
  future Reader同样 MUST 切为deferred resident ingress、先hydrate 256KiB再按decoder requiredSourceLength增量range replay，
  禁止因`residentBodyBacked`反而先整包5–20MiB重放；不可重开provider source不得伪造该能力。
  随后只在同一Reader-local native source上后台追平当前physical committed suffix并在稳定边界后加入physical live fan-out。
  `DownloadSession`上的decoder-owned playable/first-frame-required evidence只允许作为同一physical generation的transport flow-control防早停事实，
  MUST NOT作为后续Reader late-join/rebuild的replay watermark，也不得持久化成partial authority。
  任何early publish后都禁止rebuild/reset替换已对decode可见的same-generation source；
  physical partial availability、Reader-local source visibility与network admission必须保持三个独立事实。
  Reader-local source watch必须显式绑定当前physical DownloadSession/projection generation，不能只按logical DownloadId记“已监听”；
  纯consumer media demand释放只允许忘记coordinator-local kind observation，不得向Pipeline发布`ContentKind.unknown`冒充负内容证据；
  只有physical session/projection generation真正替换或`SourceEpoch`变化才可撤销该代kind evidence；
  logical id跨demand gap重解析到新physical generation时必须解绑旧projection、
  失效旧decode source-consumption/binding并从新projection重新wake。
  same DownloadId的新DownloadSession对象仍是新的physical transfer object generation；
  同一DownloadSession对象原地reset导致`SourceEpoch`变化时也必须作为新的Reader-local encoded generation，
  清空上一epoch的source progress watermark并失效旧decode/upload/output，再由新epoch首次source-ready重新唤醒；
  但若Reader-local projection已经`sealed + sourceReady + no failure`且不存在pending synchronized attachment，
  则该immutable encoded generation可以跨transient physical object recreation保留，
  source watch只更新concrete session pointer而不得invalidate热decode/upload。
  unfinished/failed/late-attaching projection仍必须创建fresh Reader-local Ingress/native source。
  physical local prepare（cold partial/artifact hydration）必须由`DownloadTransferOwner`按physical generation single-flight，
  并在任何NetLane task/transport lease/provider lookup之前启动；同步demand reconciliation不得等待该本地I/O。
  local prepare完成顺序不得取得network admission排序权：
  完成后由同一`DownloadTransferOwner`按当前`DownloadSession.effectivePriority`保持local→network rank连续性，
  lower ready work不得越过仍处于local prepare的higher demanded work，随后才交给唯一NetLane。
  local prepare普通max2只约束真实operation lifetime而不是页面资格；
  唯一例外是同一个Reader consumer、同一个accepted revision内已经由`ReaderObs.visibleCoverages/current`证明真实可见的3个`localOnly` physical work：
  当普通2槽已由其中两页占用时，第三页可使用唯一visible-cohort handoff让operation lifetime短暂重叠到3。
  `DownloadDemand.viewportVisible`必须由Pipeline直接投影该observation事实，再由LiveCoordinator原样传给physical owner，
  transfer owner不得从页号、拖动方向或current/next/previous角色猜测；跨consumer/revision、hidden、非localOnly以及第四个work都不得使用该handoff。
  如果两槽都被旧低rank prepare占用而新的high-rank demand被挡在pre-admission边界，
  owner复用NetLane既有数值high-priority/preemption margin与candidate grace；
  candidate/victim必须稳定跨过同一grace后才单次取消一个最低rank active prepare，快速滚动导致candidate变化会重置grace。
  必须等其writer/descriptor实际退出后才补普通位；除上述同viewport handoff外，不能把2槽变成隐含current-only gate、瞬时抢占风暴或一般临时扩容。被取消的durable prefix继续是可恢复物理事实：
  0-byte demand重排local prepare，已有prefix则回到post-local network admission排序，均不得丢claim、删partial或越过更高rank work。
  被scheduler撤销的local prepare如果已经进入generic `Artifact.restore`/whole-file rehash，
  现有`TaskControl` MUST继续下沉到该restore operation；
  受控CRC仍在worker isolate执行，但cancel MUST终止worker并及时释放其bounded local-operation占位；普通restore/seal的非受控CRC语义保持不变；
  storage只观察cancel，不得读取priority或建立第二scheduler。
  verified-equivalent incomplete partial若store暴露metadata ranking capability，
  index中的state/bytes只允许用于候选排序，最终选中id仍必须经过`openPartialDownload()`的root/locator/length/resume-owner物理校验后才能成为body authority；
  metadata与最终open不一致时必须回退historical physical scan，严禁把index bytes直接当partial proof。
  cold partial durable chunks与artifact-cache replay必须复用composition唯一`ArtifactCacheReadScheduler`并按动态physical priority分块取lease，
  前移不得变成3/7无界本地I/O。pending local-read若持有scheduler-owned `PriorityObservableTaskControl`，
  其rank变化直接唤醒同一`ArtifactCacheReadScheduler`重新pump pending队列；
  因此已排队的background页升为transition/current时可立即按新rank竞争，而不是等待无关I/O释放lease后才偶然重排。
  该seam只传播既有scheduler事实，不取消/重开already-admitted read，也不产生Reader-owned gate或第二local scheduler。
  Reader-local native source replay 的后台 reserve/copy/file-range 同样只能作为 execution seam：`DownloadIngressProjectionRegistry` 的 scheduler-owned control 必须贯穿 `Ingress -> BackgroundWritableEncodedSource -> native source-write worker`；
  pending source-write worker 必须按实时 priority 排序并响应 queued cancellation，in-flight native operation 仍须真实退出后释放 slot。decode worker 与 source-write worker lifecycle 必须显式分离，由 composition 并列 prewarm/shutdown，不得用 decode API 暗中拥有 source mutation worker。
  native decode 也必须保留同一 scheduler control：`DecodeLane CancelToken -> DecodeSession -> ScheduledFrameCursor -> NativeCursor -> native decode pool`。pending decode 在 worker admission 前消费同一 cancellation；numeric priority不在bridge镜像或订阅，而在每次pending selection时直接读取同一TaskControl的实时值。current/nonCurrent 只表达 execution class，class 内按scheduler rank/sequence排序。role升为current时必须先迁移DecodeLane numeric rank，再迁移同一native request的execution class，禁止native pool用独立addFirst/FIFO policy代替scheduler。request一旦取得worker，cancellation不得提前释放`_activeRuns`或cursor/source generation；source retirement必须等DecodeLane/UploadLane对应task真正退出。详见 ADR 0339。
  worker isolate exit由各自pool安装一次process-lifetime listener：worker至多持有一个当前active-response completer，exit直接结算该请求并把dead worker从live scheduling set退休；每请求只拥有短命response port/subscription，禁止再把长期exit Future通过`then/Future.any`挂到每个请求。pool在仍存活时有界补齐worker，`pump`不得再次调度exited worker；真实capacity用active-run lifecycle结算，worker identity先退休也不能让尚未unwind的FFI被当成已释放。replacement spawn失败但仍有live worker时只允许容量降级，queued work必须保留并继续由surviving worker执行；只有live worker归零且replacement仍无法启动时才可终止尚无法执行的pending。decode pool临时只剩一个live worker时non-current不能占最后slot。NativeCursor在batch decode等待期间被dispose时，返回批次中尚未转交的所有native frame立即release，不能写回已dispose的prefetch queue。详见 ADR 0338。
  durable artifact authority 的 metadata snapshot 仍由 `SqliteIndex` 唯一拥有；artifact object/replica/storage-root 直接在 owner connection 的一个短 read transaction 中形成同一 snapshot。约0.13ms的该查询不再常驻 background read isolate；真正的body/access I/O仍走既有异步边界，recency touch仍在 `StorageWriteScheduler` admission 后交给专用 SQLite worker。详见 ADR 0328。
  durable cold-partial只读lookup必须由persistent index/file直接裁决，
  hit/miss均不得为读取或存在性探测materialize durable-store `DownloadSession`；store session只允许用于durable mutation。
  若 exact ready durable artifact 已经以完整长度成功恢复进当前 ephemeral `DownloadSession` generation，
  则该次完整读取本身形成仅对同 exact id / 同 epoch / 同最终长度有效的 operation-scoped durable proof；
  紧随其后的 promoted handoff MUST 直接消费该 proof，禁止立刻再次通过 backend `exists + length`/SAF preflight 复核同一正文。
  partial、verified-equivalent restore、长度继续增长、epoch reset 或普通 Reader cache open 均不得复用此 proof，
  仍按既有 persistent preflight 规则裁决。prepare append出的prefix可直接进入既有Reader-local ingress；
  prepare完成后才判断是否仍需network task，若已promoted或完整可本地完成则直接短路。
  `downloadStarted`只描述真实provider transport attempt，本地hydrate/completion不得占用provider lifecycle。
  verified跨版本等价只允许在acquire前把尚未创建exact session的新claim加入既有direct verified physical authority；
  若proof同时命中多个既有owner，resolver按promoted、active writer/run、
  demanded、committed prefix及长度/priority稳定择优，复用其中一个而不创建第三owner，也绝不事后merge两个已存在session。
  source-resident且非artifact-cache authority的body不得跨版本join，弱证据仍不得进入physical identity。
  Scheduling-only migration of an already-established physical claim is not a lifecycle edge:
  existing-scope priority/role changes MUST NOT re-emit demand-lifecycle Trace or reattach Reader ingress/source-watch ownership。
  consumer 对 logical `DownloadId` 的 physical/version/canonical resolution 是 acquire-time state；
  只要同一 logical claim 仍被该 consumer 持有，role/priority migration MUST 复用已选 physical carrier，
  只有新进入的 logical `DownloadId` 才重新 resolve。该复用仅省略重复 identity resolution；
  physical/exact identity、checksum proof、completion intent 或 logical identity 发生变化时仍必须走完整 authority path。
  Satisfied Reader-local media work follows the same principle:
  when an exact DecodeSession is authoritative static with no pending source revision and `depth + preparedDepth >= 1`,
  a role/priority-only DecodeDemand migration must update control metadata without enqueueing another DecodeLane task;
  an exact ready retained static UploadSession with no successor/failure/in-flight prepare may adopt the new UploadDemand revision/role without an UploadLane task.
  These fast paths never apply to animation, missing work, source-generation changes or failure recovery.
  Chapter-command page stall属于physical-progress observation：窗口只在连续没有transport cursor/committed bytes增长时成立；
  低于64KiB snapshot quantum的真实网络增长由timer到期时直接读取session当前cursor确认，不通过增加snapshot/trace频率实现。
  composition-owned `DownloadJob` 的单次transport attempt失败只负责关闭response并把partial恢复为idle/resumable，
  不得抢先把session发布为consumer-visible `failed`；
  `DownloadTransferOwner`继续拥有retry与最终terminal failure，只有retry不再允许时才发布`failWithoutWriter`。
  page-promotion watchdog在lower physical run已进入`queued` open或`networkAttemptActive` body且lower read-stall authority有效时必须让权并重新计时，
  只在无lower active phase且无真实字节进展时执行owner-level reclaim，避免两个同窗watchdog竞速reset。
  `VersionPageAuthority`位于version relation与READY/cold-partial/hot physical consumers之间，
  只拥有scoped direct verified candidates，不拥有logical version head或durable binding。
  `HomeLibrarySession`从完整durable relations、visible entries与按需hydrate但不进入Home projection的manifest cache构造`library-version-relations` scope并原子replace；
  每条verified mapping发布predecessor↔successor两个direct affine resolver，manifest/revision移除会撤销candidate。
  `ArtifactCacheManager`注册同一authority resolver，`PartialDownloadHandoff`与physical acquire均通过同一candidate集合选择已有state；
  无existing state时 exact demand仍创建自己的session。physical acquire不是永久exact-first：
  正在demanded的exact session保持原physical generation；
  已idle/retained的exact session则与verified equivalent carriers一起使用现有authority/committedLength排序，
  下一次claim可直接绑定更先进carrier而不创建late alias或合并旧session，旧exact继续独立存在直到retention回收；
  若logical id尚无exact session，则仍可使用registry acquire-time alias快路径。
  partial checkpoint与automatic promoted handoff保持carrier自身exact id，
  显式durable command仅在其exact target经acquire-time verified physical alias成立时zero-copy materialize该target。
  Reader只batch hydrate相关chapter并确认compact authority；
  Home compact snapshot只属于列表启动加速，若同exact chapter已经hydrate出真实manifest，
  canonical media scope构造必须让hydrated manifest覆盖compact `_entries`与orphan entry，
  禁止placeholder page id/URI反向遮蔽真实resolver；
  已验证mapping不得再展开whole overlap page pairs，缺mapping时是否值得执行bounded affine proof只查询实际chapter READY/partial bindings与hot sessions。
  初始proof默认最多8个predecessor位置：首/中/尾先分类candidate offset，只有offset分歧/mismatch所在区域继续递归二分，预算耗尽后的未知span保持gap；
  成本因此与8k/80k pageCount无关，后续普通direct source open的自然strong-identity observation继续切裂/扩张。
  page mapping的复用authority统一是`VerifiedComicVersionPageInterval`集合：
  interval在predecessor index坐标中保存`[start,end)+offset`，whole overlap仅是一段；
  Home runtime按段发布resolver，manual durable reuse按interval求唯一index，多跳baseline把后一边interval平移回前一边坐标后求交并合并同offset相邻段。
  mapping级`successorOffset`继续承担legacy/default structural candidate与page-order职责，但不再单独授权正文。
  runtime resolver不再建立whole-chapter `_targetIndexes`；
  `readerPageDownloadId`把`PageAsset.index`作为不属于identity/serialization的`pageIndexHint`随活跃请求传递，
  resolver先做chapter/revision检查，再以hint O(1)定位manifest slot并复核pageId+URI，错误/缺失hint不做version fallback。
  interval evidence的在线更新沿现有source transport旁路回传：
  只有direct response可从已解析request URI产生`sourceVerifiedReuseIdentity`诊断，
  `ChapterResourceAccess`在manifest/page/index已知处把它上报；
  Home relation owner以最多1024条瞬时observation做跨版本identity配对并串行更新compact intervals。
  该缓存不是storage/cache authority，不持久化page pair；
  无变化不写derived relation，mismatch仅切局部coverage，same identity在另一index出现时可形成新的局部offset。
- speculative encoded读取预算属于application/composition resource owner，不属于Pipeline、RoleWindow或NetLane admission：
  `DownloadResourceCoordinator`持有共享`SpeculativeEncodedReadBudget`，
  默认50MiB并由App设置`readerPrefetchReadBudgetMiB`动态更新；
  网络physical task与resident/local replay只在真正请求下一encoded-byte quantum前消费该gate。
  priority<900且非required-completion的实际speculative bytes计入active budget；
  current/visible transition与`TransferCompletionIntent.required`原地bypass，同一task不得因此cancel/recreate。
  达到预算的source response释放NetLane body-read permit但保留transport lease/response/writer/partial，
  预算或priority变化后重新竞争permit原地继续；
  resident bound range再按256KiB physical quantum切分并在每个quantum前检查TaskControl/预算/local-read scheduler。
  Reader-local WebP ingress仅有一个严格有界bootstrap例外：
  新projection从已有hot partial或可range-replay durable resident body首次建立decoder source时，
  0..256KiB首个probe MAY在预算已到threshold时完成一个quantum；
  该读取完成后仍计入同一budget，最多只造成一个decoder quantum的threshold overshoot，后续replay立即恢复普通budget gate。
  该例外不授权network source growth、不改变priority/3/7/DecodeDemand/UploadDemand，也不绕过`ArtifactCacheReadScheduler`。
  平台不支持取消已提交`readAt`时只承诺“不再提交下一256KiB quantum”，不得把上层Future取消伪装成系统调用已中断。
  该预算与`cacheLimitMb`持久容量完全独立，也不是历史dev.247/248的page估算/eligibility budget；
  legacy `animatedWebpPrefetchBudgetMiB`继续失效。
显式章节下载的多页编排只在同一个 composition `DownloadTransferConsumer` 上维护有界 network window；当前 `_chapterNetworkWindow=2` 与该 chapter consumer 的 source bucket limit 2 对齐。它不是第二个网络 scheduler：每页仍以 `TransferDemand(completionIntent=required)` 进入唯一 `DownloadTransferOwner/NetLane`，chapter 层只决定何时把下一个 exact page demand 加入同一 demand set。窗口采用 sliding refill 而非 batch barrier：任一已入场 page **完整完成 promotion + durable persist/materialization** 后，chapter owner 移除该 exact demand并立即允许下一页补位；不必等待同窗另一页结束。首个 page failure/cancel 后 MUST停止新 admission，并先等待已入场页收敛/取消后再结束 command，避免 zombie claim/writer。窗口不得扩大 NetLane normal/current 容量、storage-write quantum、50MiB speculative budget或partial-retention policy；窗口宽度变化也必须继续受这些既有资源 owner 约束。
普通 response 进入 `DownloadJob` 后先合并 transport 的任意小块：
首批约 16 KiB，后续按 64 KiB source-progress quantum 提交到 `DownloadSession`。这与 WebP decode-prefix hint 是两个独立概念：
- local/content/file/asset prefix quantum：1 MiB；
- remote prefix quantum：256 KiB。
`DownloadSession` 保证连续前缀、单 writer、validator/range、seal 和 promotion。生产 composition 把这条物理链声明为 image transfer，但不把图片语义下推给 `IoTransport`：`DownloadJob` 只读当前 generation 的 bounded metadata prefix，并复用 `hasSupportedEncodedImageSignature` 做 image-body admission。prefix 已达到 sniff 上限仍无支持签名，或较短 final body 结束仍无支持签名时，统一产生 `sourceMediaSemanticRejected`；JPEG/PNG/AVIF/HEIF 等合法静态正文仍可保持 `ContentKind.fallback`，opaque URI 也不受影响。`DownloadTransferOwner` 的 local-prepare completion、NetLane 入场前 local completion 与新 source/network/resident generation 必须经过同一 gate；被拒 generation 先 reset 并删除 partial/final authority，再发布 terminal source failure，禁止把 HTML/JSON partial 留给下一次 Range resume。已有 durable `artifactCache` resident body 是例外：sessions 缺少精确 storageId+generation，不得抢占其 presentation generation-aware recovery；这类历史 carrier 继续由现有 cache recovery 精确失效。
网络 attempt 生命周期与 playback artifact authority 分离：
已有 committed partial 在 transport restart、无 validator 或 Range 拒绝时保持原文件、epoch 与匹配的内存 Ingress。
strong validator 仍优先直接 Range resume；
无 validator但已有可信 total length 时，`DownloadJob`先请求最多64 KiB的尾部 overlap Range，
只有精确206、精确range start、total length与旧记录一致且 overlap逐字节一致时，才从旧 committed boundary继续单调 append。
服务器忽略 Range而返回200时必须复用同一个response进入完整前缀CRC catch-up，不得为了fallback再打开第二条full response；
probe不适用时才直接从 byte 0 catch-up。full-body continuation采用两级成本admission：partial<1MiB不限制；
1–8MiB只有动态TaskControl priority>=820才继续；partial>=8MiB只有visible transition/current的priority>=900才继续。
已经通过admission并开始消费不可恢复full-body response后，DownloadJob只向NetLane-owned CancelToken报告attempt已投入wall time与response已消费bytes；
NetLane在active victim selection中把时间成本按5s尺度、流量成本按4MiB尺度映射为同一连续`costScore`；
同时计算bounded +100投影与base→current-safe headroom投影，当前取两者间`1/3 bounded + 2/3 headroom`固定插值。
该retention只影响“取消谁”，不改变pending/admission priority；logical detach后成本仍有经济意义，但不能单独占满全部安全headroom。
priority1000 current始终保留既有40点preemption margin。
被defer的DownloadId以当前committedLength作为composition `DownloadTransferOwner`内存记忆，
低优先级demand detach/re-add不得在partial未增长时重新probe；length变化或priority达到对应门槛时必须清除defer并重新probe，因此该状态不是持久endpoint能力。
Range probe本身仍允许；admission不得读取endpoint hash、`duplicatePrefixBytes`、decode/playback状态形成policy。
所有重复校验字节只用于 continuity proof，不写 artifact/Ingress；
不一致、catch-up未完成即取消或失败只终止当前 network attempt，不使旧 playable prefix倒退。
scheduler/consumer typed `ErrorCode.cancelled`只表示attempt lifecycle结束：
DownloadJob必须flush已到达bytes并pause writer，`DownloadSession`保持`idle/failure=null`与原committedLength；
`DownloadState.failed`只允许表达真实network/content/validator/artifact failure，
NetLane preemption不得污染partial validity。
只有明确 DownloadId/owner 不匹配、artifact corruption、显式 evict/清缓存才允许减少 committed playback bytes。
`restore()` 在现有 Ingress 的 epoch/length/kind/sealed 与 artifact 已一致时不得重建 encoded source；
缓存元数据恢复期间允许 attachDemand 与 attachIngressProjection，仅 writer 准入受限。
已 receiving 且仍有 demand 的传输不会因 observation revision 机械重建；current priority 变化在同一 lane/session 上迁移。
若完整200 catch-up已经消费并校验足够覆盖旧committed prefix且CRC明确不一致，`DownloadJob`只标记`confirmedFullBodyPrefixMismatch`证据；
`DownloadTransferOwner`在run/writer释放后可`resetIfIdle()`退休该旧generation并只允许一次clean offset-0 physical restart。
该路径独立于普通RetryPolicy，其他`resumeRejected`仍terminal/preserve-prefix，防止把弱网短读或provider异常误判成应删除partial。
未 promoted partial 与 source/network task 的热 owner 是downloads层应用级 `CompositionDownloadTransferRuntime`中的 `DownloadRegistry/DownloadTransferOwner/DownloadSession/Artifact`，
不是Reader route、chapter command或`ArtifactCacheManager`。生产 App 由`PersistentDownloadComposition`统一拥有该runtime、
唯一`PersistentDownloadArtifactStore`与`ArtifactCacheManager`生命周期；
源码物理布局上，durable artifact/replica/partial store主体位于`persistent_download_artifact_store.dart` part，
schema18先对历史SAF wrapper解包off-by-one产生的`/content://...` root/locator做metadata-only canonicalization（正文不搬迁、
不制造Direct proof），schema17 dirty-open promotion recovery位于`artifact_promotion_recovery.dart`，
partial resume metadata/helper位于`persistent_download_partial_resume.dart`，
structured download placement/export 的目录claim、placement write-tail、
export ordinal、`.zic.json` manifest、flat→subdirectory迁移、
冲突/目录扫描与structured/sibling materialization责任位于`persistent_download_structured_placement.dart`的`_PersistentDownloadStructuredPlacementMixin`，
`PersistentChapterDownloadService`实现位于`persistent_chapter_download_service.dart`，
chapter contracts、Memory fallback、composition与management projection留在`chapter_downloads.dart`；
这些拆分仍由同一个`PersistentDownloadArtifactStore`实例承载，不形成新的运行时authority；
Reader current/prefetch和显式chapter command仅attach scoped `TransferDemand`，whole-comic只聚合chapter command。
同一exact `DownloadId`跨这些consumer共享单session/writer/request；cancel只移除自己的claim，effective priority取聚合最高值。
claim的completion intent与priority正交：
Reader机会性prefetch可受costly full-body catch-up门槛约束，显式离线命令即使priority较低仍要求最终完成。
logical claim消失只影响调度，不触发durable I/O；hot partial继续属于composition runtime。
composition owner必须对idle physical registry执行有界retention：
最近idle promoted immutable physical generation默认以8-session LRU hot tail保留，普通logical window detach不得立即销毁；
只有超过该composition预算的oldest victim才在既有`ArtifactCacheManager` ordinary handoff收敛后退休。
该预算只保留physical/session generation authority，不扩大Reader/Pipeline/NetLane窗口或复制第二份artifact正文。
unfinished prefix在独立的32-session/256MiB hot partial预算受压或runtime真正dispose时，
仍可经`PartialDownloadHandoff`进入cold durable store；普通App background/paused不得为了保住hot partial触发durable/SAF复制。
该hot partial预算必须约束实际recoverable workspace正文，而不能只约束registry对象：pressure victim只有在promoted/partial handoff成功后才可退休，退休时必须同步删除session自己拥有的`.part/.bin`及sidecar。borrowed durable spool与resident body属于其它authority，retirement discard只能release lease、绝不能删除其正文。`DownloadSession.dispose()`默认仍只关闭生命周期；只有retention owner在durable handoff已证明后显式传入discard intent，避免把“dispose”等同于隐式文件删除。显式required completion可绕过50MiB speculative-read gate并保留当前active prefix；该active/recoverable正文是完成/崩溃恢复成本，不属于idle retention泄漏，也不得为了降低private占用把NetLane hot append改成同步SAF provider write。
production composition的fresh mutable artifact使用由App私有support identity稳定派生的recoverable transfer workspace，
而不是pid/nonce一次性Reader目录：
任务界面移除或进程被杀而未执行Dart dispose时，下一runtime必须先以同一deterministic `DownloadId` artifact path执行`DownloadSession.restore()`，
直接恢复磁盘上实际存在的连续prefix，再由Reader ingress/decoder自行判断现有N字节可解码多少；只有正常transfer demand仍需要更多字节时才进入NetLane续传。
该recoverable staging与用户选择的SAF/POSIX下载根完全正交，是app-private cache/staging而非第二durable cache authority；
decoder的playable/needMoreData事实不得反向决定partial persistence、checkpoint或network admission。
写入/恢复失败必须保留仍有效的hot owner/物理prefix，sessions/Reader层不得知道durable store或retention budget。
自动promotion handoff对同一immutable session成功一次后不得因后续snapshot/demand churn重复探测backend；
显式required exact barrier仍必须重新确认目标durable。
store内部用于materialize已完成immutable bytes的session/job不是source/network owner。
跨版本共享writer只允许acquire-time verified physical alias：
新exact identity尚无session且direct verified equivalence指向一个或多个可复用既有physical session时，resolver只择优join其中一个；
两个已存在session不merge，multi-owner proof不得再派生第三owner，source-resident非cache body不join。
physical session创建权只属于transfer acquire/reconcile owner；
Pipeline/Reader的presentation/read-only projection（PageStream、
progress、fallback bytes与startup readiness）只能做non-creating lookup，
必须等demand reconcile完成verified alias后再观察resolved owner，禁止`get(exact)`抢先制造session。
claim保留exact URI作为source provider，physical session仅保留首个exact ID作为hot artifact anchor；
transport选择与真正的full/range/resume `open()`都必须使用当前provider exact URI，
绝不能把physical anchor URI传入另一个版本consumer的transport。
committed prefix仍属于physical session的共享resume authority，但ETag/Last-Modified属于产生它们的provider exact request URI：
physical alias切换provider时不得把旧URI validator带到新URI，只有`resumeValidatorsFor(actualRequestUri)`命中同一URI才能发strong Range；
scope不匹配时保留partial并走既有validatorless overlap continuity proof。显式离线完成仍materialize自己的exact durable ID。
dev.228起已删除最后的late verified-equivalent promotion observer/takeover；
verified relation不得在artifact commit后异步改变已经存在的physical owner，只有新的demand acquire可建立physical alias。
physical→durable partial/artifact persistence属于正常durable边界，不得因历史trace名含`session-handoff`而删除。
dev.229起cross-version cold partial不再由版本warmup复制到目标exact key；当前durable prepare选择由ADR0309修订：
recoverable session-local artifact仍优先；
进入durable tier后exact与direct verified-equivalent READY/partial共同作为已有物理state候选，
完整READY优先、partial取最长，同authority/同长度时exact优先；
最终选中candidate仍必须经过`openPartialDownload()`物理校验，跨版本validator必须清空，后续continuity仍由DownloadJob overlap proof裁决。
durable lookup保持在async prepare边界，不得进入同步Reader demand planning。
exact POSIX cold partial在backend提供exclusive adoption capability时可直接成为现有physical `DownloadSession`的active spool：
仅允许idle/empty/no-run/no-writer session切换到已验证indexed `Artifact + CacheIndex + storageRootId`，
保持session identity/epoch/demand lease/Reader ingress不变；
persistent store在借出期把该exact id视作busy，trim/clear/invalidate/第二次adoption不得删除或解绑该spool，直到session dispose释放borrow。
借出只转移正文spool的使用权，不转移持久索引写权：adoption初始同步仍在`PersistentDownloadArtifactStore`当前per-id serializer内完成，
之后`DownloadSession`的partial/ready同步、reset或evict必须经`DownloadCacheMutationOwner`回到store的exact/physical serializers，
禁止让session自己的cache tail成为同一SQLite事实的第二writer。活跃borrowed spool的progress checkpoint必须先flush同一Artifact writer，
再把该次flush后捕获的精确committed length经同一mutation owner写回persistent index；
checkpoint之后继续append但尚未进入下一checkpoint的bytes只是crash tail，进程终止后不得提升为durable authority。
`Artifact.adoptExistingPartial`只证明非link且正文至少覆盖indexed committed checkpoint；
正文若更长只代表未checkpoint crash tail，adoption必须先截回indexed长度再继续，若更短才按corruption拒绝；checksum保持dirty，完整CRC仍在seal边界唯一计算；
本地prefix L只设置`networkStartLength`，不得伪造transient transport cursor。
generic SAF exact partial、verified-equivalent candidate及无capability backend继续经共享`ArtifactCacheReadScheduler`走原stream-copy fallback；persistent canonical SAF physical partial不是generic fallback：它必须先由store把同一authority安全迁移到Direct transfer staging，再以borrowed spool adoption给hot session，避免本地body被投影成`receiving from 0`并在revisit重复whole-prefix replay。跨locator迁移的obsolete-prefix CRC必须在这次实际copy中累计，禁止为hot takeover先独立重扫整段SAF；新Direct authority提交后，旧locator只留下durable cleanup debt，由cleanup owner异步执行delete-time authority/length/CRC复核，Reader cancellation不得等待该清理（ADR 0340）。
SAF physical partial的`.meta`只提供resume加速；
冷打开必须直接以`open()`完成sidecar存在性与descriptor建立，不得先额外`exists()`重复provider路径解析，
missing/invalid sidecar只回退为空resume state，不能否定已通过indexed physical row且正文至少覆盖indexed checkpoint的partial authority；
对更长正文的只读fallback也只能暴露到indexed checkpoint，不能把额外tail当作已提交bytes。
当前实现仍在local prepare内先把Reader ingress有序replay到L再放行NetLane admission；local replay与network suffix并发仍是目标架构的后续子阶段。
Animated WebP holder/cursor与partial-prefix循环资格仍仅属于DecodeSession/playback，不得决定transfer/cache ownership。
当前循环证据要求至少2个真实decoded frames，并满足旧`partialLoopMinFrames`门槛（默认30帧）或累计decoded frame duration达到约1秒；
后者只避免低帧率动画已有足够可播放时长却被固定帧数冻结，不改变下载/网络水位。
当unsealed partial已证明达到该循环资格、decode因needMoreData进入waitingSource但当时仍有buffered frames时，
最后一个buffered frame被消费后可由既有decode refill wake重新进入partial-prefix loop；
`DecodeSnapshot.partialPrefixLoopEligible`只暴露这一瞬时decoder资格，不能成为source-growth、transport或partial authority。
对已识别WebP，unsealed source且尚无成功frame时的native decode exception可沿既有prefix hint/source revision wake作为provisional prefix failure等待增长；
source sealed或已有成功frame后的decode exception仍是authoritative failure。
dev.230起artifact cache彻底删除directed hard alias/rekey：explicit migration也只登记symmetric verified equivalence；
ordinary Reader promotion若已存在同长度direct equivalent durable artifact则不复制第二份exact body，
只有required durable command barrier才materialize exact identity。
dev.231起required durable target由physical owner当前claim语义决定：
若physical A正服务required exact B，promotion handoff直接把A的hot/resident bytes持久化为B，不先materialize A；
只有无required target的ordinary promotion才以physical session.id作为默认durable target。
dev.236起Reader current transfer progress同样只投影demand reconcile后resolved physical `DownloadSession.snapshot`：
Pipeline不得维护logical exact-id→session第二映射，Reader只消费只读`PipelineTransferProgressFeed`；
Reader-local ingress诊断scope使用physical session lifecycle ID。active source provider属于physical task lease：
logical claim lifetime、transport lifetime与request/provider选择彼此分离。
task可通过通用`retainedTransportFor(uri)`取得独立于consumer close边界的transport capability；
consumer-bound transport在真实dispose时仍必须cancel并等待物理退出，task-retained transport可继续同一physical writer/partial。
provider exact一旦随physical network task admit即成为该task lifetime事实；
verified-equivalent logical exact/current/rank变化只能迁移同一NetLane task priority，不得为了切URI取消并重开provider。
只有attempt完成/失败或consumer-bound transport真实dispose才结束该request authority，后续task再从当时preferred claim选provider。
NetLane policy rank只决定physical task slot/preemption并独占restart-cost retention；
costly full-body catch-up仍由`TransferRankPolicy`把preserved-prefix成本映射为cost rank后与demand rank比较。
`DownloadSession`另拥有transient transport cursor（attempt sequence/active/absolute network cursor），
由`DownloadJob`随实际response字节推进；
它可在Range→200重读时落后于monotonic committed partial，但绝不参与resume、identity、durable或rank。Pipeline/Reader只读投影两者：
authoritative/max partial保持唯一的完成度直线，current transfer只通过`PipelineTransferProgressFeed`发布并由`PipelineFrameScheduler`合并到安全frame boundary；
当total未知时connecting/prefix replay只允许显示不定的transport活动提示，禁止把`transportBytes/partialBytes`画成第二条0→100完成度；
只有total已知后，当前transport才以VibeVenera speed-color语义的波浪线显示，用来区分prefix replay、attempt reset与真实partial增长。
sessions不得知道Reader role、1000、Venera/Mihon/source类型，也不得建立第二scheduler/transport registry。
显式整本下载的进度投影链固定为 `DownloadSession -> ChapterDownloadSnapshot -> WholeComicQueueJobSnapshot`。
`WholeComicDownloadQueue` 拥有整本任务的调度状态与章节集合，订阅章节服务变化并发布 `completedPageUnits/totalPages/completedPages/hasPendingWork` 及页级 `fraction`；
Home 封面和下载管理只能消费这一整本快照，不得分别按章节数或自行扫描章节快照重新聚合。未知总页数的活跃章节只影响 pending 状态，不得伪造已知页数分母。
Home/书架封面上的下载完成标记只表示**显式下载命令完成后的临时反馈**，不表示 durable cache residency。单章节命令和整本队列命令必须区分；
整本标记只能由 `WholeComicQueuePhase.complete` 产生，任意一个 `ChapterDownloadSnapshot.isComplete` 无权推导整本完成。
该反馈属于 Home Presentation、以 canonical comic identity关联，并在用户进入该漫画详情时消费；真实离线状态仍由 downloads/artifact owner维护。
physical transfer 的 setup、local completion 与 body attempt 共用同一 terminal/retry 边界。
`provider.transportFor`、retained transport 解析或本地 seal/promote 抛错时，
`DownloadTransferOwner` 必须在 finally 中释放 provider lease 与 task key；
可恢复 network setup 只进入有界 recovery rounds，耗尽或非 network 错误发布 `DownloadSession.failed`。
一旦进入 `DownloadJob` 的 provider attempt loop，transport/open/body network failure 的唯一 retry budget 就是该 consumer 的 `RetryPolicy`；
attempt exhausted 必须直接发布 terminal failure，禁止再进入 owner recovery 形成乘法重试。
claim/priority-only scheduling migration 只能取消过时 sleeper，不得清 terminal failure 或重置 owner recovery budget；
只有真实字节进展、成功完成、physical generation reset/replace 或 session 真正退休才可重置。
`completeWithoutTransport` 的 seal/checksum 失败先关闭 writer；
若失败来自 local prepare 的完整 partial，则重置该损坏 generation 后只进入一次正常 provider admission，
不能反复校验同一坏 partial 或形成 ensure hot loop。整本队列 JSON schema 3 与 effective `storageRootId` 绑定；
root/SAF tree identity 变化时，历史 complete 投影先清空并通过当前 `ChapterDownloadService` authority 批量 reconcile，再允许调度。
pause/cancel/close 对底层 cancel 与 active run 都采用 10 秒有界等待，队列文件由同目录临时文件 flush 后 rename 替换，旧完整文档在提交失败时保持权威。
内存章节后端只作为 fallback/test tier：显式 manual download 从任务开始即保护该 chapter identity，trim/clear 跳过其完成或 partial 页面；
删除最后一个同 comic 章节才释放 memory placement。
生产显式下载在 probe/placement/mutation 前必须先完成 durable handoff，因此不建立 RAM manual task 向持久后端的第二套迁移协议。
下载管理页对 chapter download、whole-comic queue 与 cache coordinator 保持非拥有关系，
版本/revision 删除确认也只消费只读 `ChapterDeleteImpactProjection`：production command owner 先 hydrate exact entry，再由当前 durable `ChapterDownloadService` 按 `entry.toManifest()` 与同一 `_downloadId` 规则构造真实 mutation target；artifact store 在同一 durable index authority 下把目标 exact binding 按 artifact/path 去重，并把目标集合之外的 exact historical/provider binding 与 canonical `physical_media_artifact` binding 作为共享保留引用。Presentation 只显示 exact binding 数、受影响页、预计独有物理对象/bytes 与共享保留对象/bytes，不读取文件系统、不复制引用计数，也不获得删除权。该 projection 只是确认时快照；用户确认后仍调用原 `deleteChapterFiles`/`ChapterDownloadService.delete`，执行期由 artifact/replica owner 按最新引用关系再次判定，因此并发新增引用可让实际回收少于预览，但不能让 UI 按旧预览强删。该预览只描述 indexed physical body/object 的回收/保留，不宣称结构化目录项或 provider 副本数的精确删除量。
`HomeLibrarySession` 是 download-management projection owner：
Home 在首个可见 frame 后及 durable composition adoption 后后台生成包含 orphan entries 的投影；
持久下载后端用一个 artifact-index snapshot 同时完成 orphan discovery 与 chapter snapshot inspection，
同一 service 的并发 refresh single-flight。
route 首帧和后续更新只消费/订阅该投影，打开、重复进入及退出 route 均不重新读取 library、artifact index 或 cache usage；显式刷新仍委托 Home 重建一次投影。
Home startup snapshot只持久化轻量download summaries、不持久化physical cache projection，
因此首次进入自动缓存/Canonical tab若该projection仍为空，screen在首帧后通过同一个Home projection owner lazy hydrate一次authoritative management projection；
hydrate完成前显示pending而不是回退到exact snapshot rows。自动缓存统计仍仅在进入对应 tab 时按需读取。
若首帧仍绑定 bootstrap composition，post-frame handoff 只负责 ensure/adopt durable services、
按 identity 重绑 screen stream 与读取最新 Home 投影；
旧 bootstrap 回调不得回写新 composition，首个 route instance 必须随 Home 后台投影更新显示 durable 下载项。
下载版本运行时权威由 `HomeLibrarySession` 的 `ComicVersionBaselineProjection` 收口，而不是由下载管理页遍历历史关系。
历史 `ComicVersionRelation` 只保存 provenance/verified mapping；
resolver 区分 `latestKnownHead`（来源确认的最新候选）、`shelfHead`（书架实际采用版本）和 `downloadHead`（具有显式 manual download 状态的最高已采用版本）。
发现新版只更新 latestKnown，不得自动改变 shelf/download head。
手动 Tab 先按 `isManualDownload` 准入，再只消费 resolver 给出的 direct predecessor→downloadHead 章节映射；
唯一历史路径可在 resolver 内一次组合，分叉/多路径则拒绝自动归并。未发起的 library/Reader-cache 后继版本不能吞掉旧手动任务；
`downloadHead` 绝不能限制 immutable artifact cache：
cache/artifact owner 独立消费完整 source-verified version relations 与已登记 page equivalence。
自动缓存 Tab 是 physical management projection：
active verified shared media 归并为 family/chapter Canonical 行，未验证/gap/revoked 状态保留 Exact。
Home relation publication 后的 cache-residency backfill 只扫描已经存在的 READY/partial index；
READY 通过 physical binding 零正文复制收口，historical exact partial 仅在 live authority 能解析 canonical physical coordinate 时先提交 physical prefix 再删除未变化 exact row，
busy/race/gap 全部 fail-closed。几十个未打开/临时版本因此只增加 compact history，不产生下载管理逐页状态或 UI 热路径图搜索。
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
  -> Flutter ui.Image/RawImage（Reader默认）或显式opt-in Android texture
```

稳定约束：
- durable READY 的 physical completeness 与 Reader-local encoded ingress hydration 是两个独立 ownership boundary：
  `DownloadSession.bindResidentImmutableAuthority` 可在正文已完整、
  promoted 且由 artifact-cache authority 持有时让 Reader projection 仍从空前缀开始；
  只有 DecodeDemand/UploadDemand/retained output 已经拥有 media source 时，
  `DownloadIngressProjectionRegistry` 才先回放 256KiB contiguous prefix，
  再按 DecodeSession 的 `requiredSourceLength`/native need-more-data 以 physical replay quantum 逐段增长。
  logical remote URI 不得把已落地 Direct/SAF body 重新按 remote cost 计价。
  READY backend 若能提供 generation-bound range reader，则 exact-length proof 与后续 range replay 复用同一 descriptor；
  reset/rebind/dispose 关闭该 capability。
  `ArtifactCacheReadScheduler` 只从真实 queued/active foreground local-read work（或明确的 operation-level holder）得到 foreground pressure；
  Reader presentation/current-output lifecycle不得预先制造 pressure，也不得保留“first foreground quantum”全局 reservation。
  该 pressure只影响本地读/写资源协调，不重新定义 page role、Download/Decode/Upload 水位。
- durable READY 的非WebP静态 presentation 可在上述body authority之外投影 generation-bound `ArtifactCachePresentationFileLease`：
  persistent store仍负责选择exact/verified physical replica，
  Android adapter只在lease lifetime内把Direct/SAF locator钉成只读PFD并暴露进程内`/proc/self/fd`；
  `ArtifactCacheManager`在交付前后校验mutation generation，Pipeline拒绝WebP/GIF并要求可信source dimensions，
  Presentation只消费file lease而不取得cache path/descriptor ownership。
  fd path不是缓存identity，Flutter ImageCache key绑定manager epoch + `storageId` + generation；
  storage_bridge的EncodedFileImageLease把同一descriptor钉到已启动的file/buffer/codec Future实际退出；
  取消listener不等于取消engine读取。prewarm等待该release完成，mounted替换/销毁只请求release而不阻塞Reader；
  release后不得启动新的读取，已有pending completer的共享consumer仍可取得首帧，失败路径同样退休租约（ADR0380）。
  平台/尺寸资格失败必须释放lease并退回既有full-byte path。
  每个lease仍独立拥有自己的release Future，但Android bridge可把同一event-loop内多个descriptor close合成一次native batch，
  避免长纵排退出时大量MethodChannel completion挤占下一Reader的local file-open continuation；
  batch不得改变任一handle lifetime，也不得把Reader teardown变成全局等待。
  该能力只删除eligible READY fallback的Dart整页encoded materialization，
  不改变3/7、decode2/1、Upload、NetLane、SAF executor或watchdog。
- Presentation 对 Pipeline WebP 首帧的接受必须原子同步 content format 与 ready state：
  一旦真实 Pipeline surface 已 present，`LocalImagePlayer` 不得保留旧 manifest/filename 推测（例如 jpeg）继续走 loading/fallback build 分支；
  首帧观测只在当前 surface 仍为权威时发布。
- opaque plugin URI不能让transport-cost policy等待完整animation metadata：
  physical/Reader ingress实际sniff到`ContentKind.webp`后，
  只投影runtime WebP cost evidence以启用既有bounded 5/3/2/1 body flow；
  该evidence不等于`animated=true`，DecodeSession的authoritative static/animated classification始终优先并可撤销cost-only推断；
- 两个 decode isolate 在进程期常驻；libwebp 帧内单线程；
- 首次 native 请求优先单帧，current 后续请求最多批量返回两帧；
- holder 是 decoded frame 的权威缓冲；可见 output 不计作 successor；
- 缺少 successor 时保持当前 output，等待 producer 通知，不进入 startup-buffer，也不阻塞其他页面 decode；
- playback 使用最近 deadline 的 one-shot wake；静态零时长帧不启动 timer；
- finite animation 到 EOF 保留最后一帧；
- metadata 未完成且 source 增长时允许刷新 demux；未封缄 `needMoreData` 等待 source revision，不用定时销毁 cursor；
  source revision 是 Reader-local projection 的状态事实，只有实际 decode fill 或 DecodeSession 已证明无需 fill 后才能记为 consumed，
  current-bootstrap 暂时门控邻页不得吞掉其 pending source wake；
  `SourceEpoch`的decode authority只属于Reader-local ingress projection，
  不得再由DecodeSession同时读取physical DownloadSession epoch形成第二generation owner；
  projection在同epoch内rebuild并替换`EncodedSource`实例时，DecodeSession必须释放旧cursor/holder并重新绑定当前source，
  异步decode期间projection epoch变化属于生命周期cancel而非内容failure，cursor复用必须同时满足projection epoch与source实例identity一致；
- target canvas 使用 contain 和 `height / width`，不裁切、不使用负位移或页面重叠掩盖接缝。

## 9. Upload 与 renderer output
- Android SurfaceProducer 的 `scheduleFrame()` 合并由 texture bridge 按 producer 持续到下一次 vsync；
  同一 producer 的重复请求共享一次真实平台调度，不同 producer 保持独立首帧调度。

primary可见upload角色仍为current、transition；
paged Reader另外允许一个冻结的next first-frame preupload（不运行隐藏动画、不扩next2/previous）；
上一 current 的 output retention通过独立 `retainedIndex`叠加 `last` upload demand，不改变该页的相对 previous/next 网络与解码角色。
远离7/3窗口时 retention只保 output，不产生 download/decode。
生产Reader保留native source/cursor/libwebp decode，但默认将RGBA一次转换为Flutter `ui.Image`并由`RawImage`呈现；
推测静态邻页仍只可在既有预算内预上传。

生产Reader默认恢复Android SurfaceProducer output；dev.311 Flutter `ui.Image/RawImage`默认实验已被09:28设备证据否证并在dev.312回滚。
SurfaceProducer路径仍使用默认platform MethodChannel、一个串行 blit lane和普通`mainHandler.post`；
同一 output 的待调度回调可合并为一次主线程 `scheduleFrame()`，但每个调用仍必须收到完成回调，且 schedule 看到的是最新 resident frame。
Reader WebP texture viewport 固定使用 `FilterQuality.low`，避免高分辨率页面首次进入横向 PageView 时同步生成 mipmap 抢占切页帧：

1. retain native frame；
2. 单 lane 复制预乘 RGBA；
3. platform thread 调用 `SurfaceProducer.scheduleFrame()`；
4. 原子替换 output retained frame；
5. 返回 MethodChannel；
6. UploadSession 记录 presentation 并推进 deadline。

生产SurfaceProducer路径的texture lease在output结束时真实释放，不回到Reader间复用池。
只有从未呈现过的预热lease可短期复用，App非resumed时清理idle prewarm；
deferred prewarm若与同尺寸的权威upload acquire竞速，池观察该进行中的acquire并等待其结果，不再创建重复SurfaceProducer。
platform queue、schedule queue/call、blit和channel dispatch继续分别计时。
正常逐帧 platform telemetry 不再在 Flutter isolate 生成重复 `frameUploaded` Trace，
达到 20ms 或 deadline/surface transition 的异常样本仍保留，完整 timing 仍由 output/frame-pipeline 记录。

## 10. Reader 资源会话 retention

Reader Host 从 `PipelineReaderSessionFactory.acquire` 获取资源会话并在退出时 `release`。退出 Reader 不等于立即驱逐整章资源：

- retention pool 最多保留 2 个无UI lease的章节会话（LRU）；TTL 为 2 分钟；lane退出后媒体为空，第三个不同key进入时完整淘汰最旧会话；
  显式切换下载目录等 exclusive storage 操作必须先排空该 idle retention pool，再检查 composition transfer consumers；
  仍挂载的 active Reader lease 不属于 idle drain，必须继续阻止目录切换。
- key 包含稳定章节/source revision、loader URI/revision 和 composition 能力指纹；临时 loader 对象 identity 不参与；
- 保留Reader-local SourcePool、Decode/Upload/media runtime这些轻量容器以及对composition transfer runtime的consumer lease，
  retention由现有Coordinator退休无demand媒体：idle立即回收，已取消但仍执行的decode/upload通过原lane真实退出回执释放cursor/source，不允许Pipeline直接提前evict；
  无新owner、timer或退休队列；重入恢复demand继续使用原source-retirement换代校验，不能由旧回执回收新代；
  physical DownloadRegistry、artifact/partial handoff与transfer workspace独立于Reader会话生命周期；
- 释放 Reader binding、page projection、playback wake、present claim 和 renderer output资源；
- 不同 key、TTL 到期、容量淘汰或 composition shutdown 时才完整逆序 dispose。

这是一条资源 lease，不是 Reader UI 缓存；SurfaceProducer不得跨Reader复用used output。

来源页打开已经持久化为 `LibraryComic` 的同一漫画时，source route lock 是该导航的唯一 presentation lock；
不得在持有同一 `sourceId + raw comicId` lock 时再次调用会重复申请该 lock 的入口。路由锁只存在于内存导航生命周期，不写入 library，也不参与持久 identity。
`LocalComicDetailsScreen`不得持有external source availability的永久nullable快照：
route进入可先等待deferred source publish，但未持久化章节的loader每次执行都必须通过Home的live resolver重取source；
因此同route重试可在source稍后就绪后恢复。

## 10.1 Reader progress 与阅读历史

Reader 页面变化产生的 `ReadingProgress` 由 `reader_runtime` 串行合并后写入 App 提供的 progress facade。
同一 Reader 同时只有一个 active writer；较新的 pending progress覆盖尚未开始写入的旧值，禁止并行 Future 倒序完成后覆盖新页码。

普通页面变化只 enqueue checkpoint，不等待 SQLite；但正常 Reader route 返回前必须先 drain Reader-local pending writer，
再通过 `ReaderProgressCheckpointStore.flushProgressCheckpoints()` 等待 storage-owned SQLite writer 的 durable barrier，
完成后才用 route-local `latestProgress` 替换 Home/详情内存投影一次。
`inactive`、`paused`、`detached` 也执行同一 checkpoint+flush，但不得把 durable barrier扩散到普通翻页。
操作系统在 barrier 前强杀仍可能丢最后窗口，文档和 UI不得声称绝对 crash-safe commit。

## 11. Identity、缓存与 artifact
- **Historical exact-carrier trust is read-routing policy,
  not identity proof.** 当当前 `DownloadId` 的 exact/verified cache miss，
  但 persistent backend 存在相同 `ContentId + sourceRevision` 的完整 READY 历史 exact carrier 时，
  `ArtifactCacheManager` 才可按用户策略决定是否把它作为只读 body authority：`strictReload` 直接回 source；
  `reuseThenRefresh` 先用历史 READY，真实 presentation 首帧后再由 `CompositionDownloadTransferRuntime` 通过既有 fresh-source recovery 异步 revalidate current exact；
  `trustCached` 只用历史 READY，不自动刷新。
  历史候选不得注册 `VersionPageAuthority`/equivalence、不得建立 canonical `PhysicalMediaId`、不得写成 current exact cache。
  若同一 logical page/revision 的 READY 候选出现多个 `(length, checksumAlgorithm, checksum)` signature，默认 fail closed；
  App 可按 **sourceId** 显式允许“完整文件也信任”，Downloads 只接收 `sourceId -> bool` capability resolver，
  不认识 Mihon/Venera/plugin。该 override 只放宽候选资格，仍要求 persistent READY 的完整 seal metadata；
  候选按 persistent logical query 的 `touched_us DESC` 稳定顺序选择。
  source override 只有在全局策略允许 historical reuse 时才生效，不能覆盖 `strictReload`。
  冲突信任另有 application-level 全局默认，当前默认开启；源设置以 tri-state（inherit/strict/trust）覆盖该默认。
  历史 plugin-scoped override 只作读取兼容；进入源设置时可把旧值展开到当前已知 source IDs。
  只有 installed plugin authority 能证明 source 集完整（静态完整 descriptor，或成功 runtime activation 已持久化完整 `sourceIds`）时才退役 plugin fallback；
  部分 runtime discovery 不得因为“当前只看见一个 source”就删除旧值，否则尚未发现的 sibling source 会丢失历史信任。
  该 resolver 只决定多个完整 READY signature 冲突时是否允许最近 historical carrier 进入 read routing，
  不建立 equivalence/canonical/current-exact authority。Reader 只上报 first-visible-frame，不拥有 URI/cache/source 信任策略。
  historical READY 一旦通过用户 read-routing 策略资格化，local-prepare owner 在 exact/partial/verified-equivalent authority 都未命中后应直接把该 sealed generation 的 range replay capability 绑定到同一 physical `DownloadSession`：
  只读取 bounded metadata prefix 建立格式证据，session artifact 继续保持 body-empty，后续 presentation 按需重放同一 generation。
  不得为了把 session 推到 `promoted` 而先经 `DownloadJob` 完整消费 historical body，再由 presentation 第二次读取；
  `ArtifactCacheTransport` 的 historical response 只保留为 bind-only 路径无法建立时的 correctness fallback。
  该 capability 只描述已选 body generation，不登记 equivalence/current alias/canonical proof。
  `reuseThenRefresh` 的后台 revalidation 若 supersede 旧 source/projection generation，
  typed cancellation 与 stale epoch/writer/run 只退休旧 attempt/consumer projection；
  只有自身确实无 source/bytes/failure 的空 projection 才允许在 attach 时 reset 到 current physical epoch；
  同 epoch 的既有 consumer prefix 必须原样保留，非空且 epoch 不一致必须走 synchronized attachment 而不是靠 reset 擦除。
  任何 stale consumer edge 都不得把有效 physical session 终态化为 failed。
  Historical reuse 的 transfer convergence 与 stale presentation lifetime 必须分层。
  `reuseThenRefresh` 在真实 external-static 首帧后仍可用同一个 physical transfer/session owner 进入 fresh-source quarantine 并重验 current exact，
  但 `ArtifactCacheManager` 同时只保留本次策略已经选中的 `(current logical id -> historical storageId + mutation generation)` 作为瞬时 **presentation-only continuity authority**。
  fresh quarantine 期间普通 exact/equivalent/historical cache routing 继续严格禁用；
  presentation 只能按该 exact storage generation 重开 file/descriptor 或读取正文，
  禁止候选搜索、注册 equivalence、写 current exact、恢复 DownloadSession 或影响 NetLane。
  fresh exact 成功、recovery 取消、policy 退出 reuse 或 historical generation 改变后该 capability 必须退休。
  Reader 顶部 transfer progress 也只是一层 presentation projection：
  当前 exact external-static identity 已真实出 visible frame 后，
  后台 historical revalidation/持久收敛不得继续显示为页面灰色 loading/progress；
  底层 DownloadSession/network activity 不变，manual force reload、
  真实 presentation failure、page/DecodeId identity 变化必须恢复进度投影。
- 同一稳定 identity 只有一个权威 request、session、artifact、cursor 和活动 writer。
  ContentId/DownloadId/DecodeId 的新 `key` 使用长度 framing，不能把带分隔符的来源字段折叠成同一字符串；
  旧 cache metadata/SQLite key 只作为兼容恢复输入，新的写入使用 framed key。
不同 identity 层不可混用：catalog identity 定位实体；DownloadId 表示确定字节版本；DecodeId 还包含 epoch、target 和 renderer；
presentation identity 只表示页面位置/输出。

缓存分为两个权威平面：

- `ResourceCacheCoordinator.responses`：
  封面、搜索、详情和章节元数据，使用稳定 namespace/identity/revision、weight、TTL 和 in-flight join；
  external artwork 使用 source-confirmed canonical comic identity + role，
  raw runtime locator 不参与 durable artwork 分区；
- `ArtifactCacheManager`：Reader 不可变页面 artifact，默认热字节 10 项/256 MiB、alias 上限 8192，并连接持久 backend。
  底层 `SqliteIndex` 与 `PersistentDownloadArtifactStore` 维护内存快照并对 `readyPageIndices` 与 `indexedRecords` 提供 O(1) 探查；
  正常 sealed Reader 热读只做存在性/长度等 O(1) 元数据校验并直接流式消费，完整 CRC-32 属于 seal/materialize/显式 repair-audit 边界，不得在每次读取时全量重算。
  SQLite schema 8 已把 immutable object proof 与 physical copy 分开：
  `artifact_object` 保留 bytes/checksum 与兼容 locator mirror，`artifact_replica` 才是 sealed 物理副本权威；
  同 artifact 可有多个已验证 replica，Direct/SAF 同根 proof 只增加该 replica 的 access alias。partial 不属于 replica。
  多个ready logical bindings共享同一`artifact_id`时，cache capacity/trim按该physical artifact只计一次正文；
  任一sibling受到pin/busy/protected约束即保护整个physical group，只有最后logical binding移除并真实删除replica时才计入released bytes。
  结构性坏副本只淘汰自身，不得连坐 logical binding 或其他 sealed replica；`accessDenied/ioFailure` 只影响访问可用性。
  `lengthChanged`的破坏性置信度按access kind区分：Direct/POSIX一次exact mismatch即可structural；
  SAF必须独立重开/重取长度二次确认，bound READY reader若首次descriptor长度异常也关闭并重开一次，
  只有重复mismatch才退休replica，第二个descriptor恢复sealed length时直接成为后续range authority。

封面 URL/token 不是稳定 comic identity；verified checksum、来源 page key、内容 hash 或用户确认迁移才可登记 artifact equivalence。
App/Reader 不得创建私有图片字节 LRU，也不得让 cache hit 共享 cursor、timer 或 decode identity。
Durable READY 的 crash-recovery ownership 与 canonical physical routing 统一收口到 schema-8 SQLite authority：
`artifact_object` 持 immutable bytes/checksum proof，
`artifact_replica` 持 sealed physical locator，`cache_entry` / `physical_media_artifact` 分别只是 logical/exact binding 与 canonical routing；
`cache_entry.path` 和 final `.meta` 都不得反向成为 sealed body owner。
dirty `StartupRecovery/CacheScanner` 只清理没有 DB/live authority 的本地 crash garbage，
并保护 DB-authoritative replica locator；
它不得因 `.meta` 缺失、格式损坏、ownerless、checksum/path 字段不同而创建、删除或重建 READY，也不得为 READY 重新 materialize `DownloadSession`。
真实正文缺失、exact-length mismatch、unsafe locator 等结构失败仍由普通 artifact→replica read path typed 检测并只退休坏 replica；
多 replica 时不得连坐其他副本或 logical/canonical binding。
mutable partial/spool继续是独立 authority，sidecar只可补充 validators/resume/collision diagnostics，
不得把 partial/final bytes 升级成 durable READY。
`PersistentDownloadArtifactStore.storePromotedArtifact()`遇到 matching READY 时先走 artifact/replica preflight并直接复用，
不得调用 session restore 去“修”sidecar；只有真正的新 materialization 才进入 mutable `DownloadSession`。
final data rename 与 SQLite artifact/replica commit 之间的崩溃窗口由 schema-17 `artifact_promotion` progress journal 闭合：
journal 只从已索引sealed length/CRC proof建立并同时保护source/destination候选，
open按DB proof完成rename/commit或fail-closed回到partial；它自身绝不成为READY，也不读取sidecar。
automatic `PromotedArtifactCacheHandoff`继续复用 matching canonical sealed body，
explicit exact persistence仍通过metadata binding/materialization满足用户durability语义。
### 11.0 可配置下载目录与缓存上限

章节下载字节存储默认位于 `<storage root>/offline_chapters`（`partial/` + `final/` + 结构化导出），
而下载 metadata authority 固定在 App-private `<storage root>/chapter_downloads.sqlite`；
结构化导出的单章 flat→首次多章转换由 `.zic.json` 的 per-chapter `chapterDirectories` 作为布局 commit marker：
当前 manifest 已有目录映射的历史章节不得因后续新增章节再次进入全表迁移扫描；缺 mapping 的单章/旧 manifest 仍按可重入恢复路径重新检查 root-level indexed pages，
迁移每成功一页先更新 exact binding path 再删旧位置，因此进程中断后只剩未提交页继续成为候选。
章节命令开始时已经持有的 indexed chapter snapshot MAY 作为本命令下载前的兼容/布局 hint：
manifest 首写、无 placement 的 legacy目录恢复，以及旧 structured 文件补 export ordinal 都应优先消费该 snapshot，
避免同一命令重复 whole-index read；manifest writer 在目录锁内仍 MUST 合并最新 previous manifest。
该 snapshot 不是最终 membership authority；下载完成后必须取得一次 fresh durable index snapshot 作为最终 reconcile 边界，
并由 final manifest commit 与 complete management projection 共享这一同一时点事实，
既吸收命令开始后出现的并发/恢复章节，也不得紧接着为完成投影再次 whole-index read；
download-cache schema 12在既有logical/artifact/replica表上只增加`cache_entry(path)`访问索引，
11→12 fast-path不得重跑旧artifact/backfill/identity/retention迁移。
结构化最终路径冲突检查通过targeted path-binding query读取同path logical siblings，不得在每页materialization时枚举整个cache index；
数据设置中的单行"默认下载目录"项只改变字节/导出目标，偏好键为 `chapterDownloadDirectoryOverride`，不是第二 metadata owner。
升级时若 private DB 尚不存在，startup 先按旧恢复语义完成可能中断的 legacy store move，
再用 SQLite `VACUUM INTO` 将生效根的 legacy `cache.sqlite` 一致快照到 private DB，
`integrity_check` 通过并原子切换后才 best-effort 清理旧 DB/WAL/SHM；已有 private DB 永不被 legacy 状态覆盖。
生效位置由 `packages/storage` 纯函数解析：所选目录缺失或为空时直接使用，非空目录不合并不覆盖，存储置于其下第一个可用 `offline_chapters(i)` 条目（空条目可复用）。
目录切换由 runtime owner 执行：
设置 UI 经 `HomeServiceHandoff.chapterDownloadRelay` 调用 `_BootstrapAppState.changeChapterDownloadDirectory`，
意图（目标位置、迁移来源 `chapterDownloadDirectoryPendingMoveFrom` 与当前 `replica-direct-v1` 协议标记）先持久化；未标记的历史 pending move 仍按 legacy whole-tree recovery 解释，
再 checkpoint 并关闭 queue/cache coordinator；已有 App-private metadata 时，当前 `PersistentDownloadComposition` 排空 transfer consumer 后直接复用唯一 `PersistentDownloadArtifactStore` 做 explicit Direct-root migration。
迁移只选择 verified READY + explicit manual/offline retention 的 sealed replica，并逐个复用 schema-9 `migrateArtifactReplica`：目标 bytes proof 先成立，destination replica/root authority 提交后才删除 source，`replica_id` 保持不变；automatic-cache-only bytes 与 mutable partial/spool 不参与根迁移，继续由原 indexed locator 读取。
全部选中 replica 提交后才 durable copy/verify `.zic.json` 并推进 `DownloadPlacement` generation/root；placement commit 后旧 manifest 仅作 best-effort cleanup。中途失败保留 pending intent 并重开 source layout，已提交到目标的 replica 不回滚，冷启动只打开同一 App-private artifact store 继续剩余迁移。
SAF 任一侧参与时 UI 禁用 automatic migration；body replace 已由 ADR0343 收口，真实 DocumentsProvider kill/reopen 仍作为独立设备证据。`moveChapterDownloadStore`/`settleChapterDownloadDirectory` 仅保留给 private metadata 出现前的 legacy 整树恢复/升级兼容，不得重新进入当前 runtime 的 private-metadata root switch。
整本任务活跃或 transfer consumer 未退出时拒绝切换；
`durableZicStateExists` 优先识别 App-private chapter metadata，同时仅为升级兼容探测 legacy 生效根 `cache.sqlite`。
源设置为每个 source 提供独立下载目录：偏好映射 `sourceDownloadDirectories` 按稳定 source identity 记录物理根，
`DownloadRegistry.layoutResolver` 只决定该 source 新 artifact/partial 写入哪个根。
durable sealed 读取始终由索引中的 artifact/replica locator 裁决，因此旧位置字节保持可读且无需启动期重建历史 READY session；
该 per-source 切换不做迁移。插件管理不再批量改写同一插件全部 source 的目录。
持久store打开期间在cache root保留`.zic-cache-recovery-required`脏关闭标记；同一 App-private download metadata DB 还由 absolute index path 的进程内 owner 与 `<index>.owner.lock` OS lock 共同排他，且该锁必须先于 SQLite open/recovery 获取，避免另一活进程被误判成 crash owner。
正常关闭删除 recovery marker 并释放 metadata owner；下一次仅在发现遗留 marker 时运行`StartupRecovery`的authority-aware local cleanup scan，普通冷启动不得支付全量扫描成本。
该 scan 对 sealed READY 只保护 DB-authoritative locator并清理无authority orphan，不执行 READY registry restore；
mutable partial 的 demand-time adoption/resume仍由其独立 physical/index owner负责。
非权威exact locator的crash清理由download-cache schema16 `storage_cleanup_debt`独立拥有且永不取得正文authority：
`temporary`在Direct/SAF随机temp create前持久记录locator并在confirmed-absent后清债；
`obsoleteSealedSource`只允许在已有immutable length+checksum proof的旧sealed source失去authority前登记；
`obsoletePartialSource`只冻结跨locator replacement或cold retirement瞬间的旧mutable prefix generation，
切换前按实际旧body计算length+CRC32，普通append/pause/checkpoint不得付该CRC成本也不得把此proof当partial validity。
普通`PhysicalPartialRecord`删除失败时必须保留row直到body+sidecar确实清除，不需要另建debt。
跨进程obsolete cleanup都必须先确认locator已非replica/partial/migration authority并重新校验当前bytes仍匹配旧proof，
路径被复用/内容改变时只能撤销cleanup intent、不得删除；hot session接管旧path时也必须撤销provisional partial cleanup。
store open只异步枚举这些小型debt rows并经`StorageWriteScheduler`定向处理，SAF只处理当前同tree、绝不tree scan；
跨locator physical partial copy不得以较短失败staging覆盖较长旧prefix，legacy exact Direct→SAF在旧root不可安全检查时必须fail closed。
schema9 `artifact_replica_migration.copying`仍是可resume进度，在schema9 owner存活时不得被generic cleaner触碰；
同一proven StorageRoot重挂载后destination/temp仅可按相同relative path重绑。
`cleanupPending` old source允许从当前proven alias恢复relative locator并重验sealed proof后清理；
final invalidation/structural retirement若要移除schema9 owner，必须先把generated migration temp转成schema16 cleanup debt。
缓存上限是同一偏好文档中的 `cacheLimitMb`（默认 512，范围 64–8192）：
`ResourceCacheMaintenancePolicy.forArtifactLimitBytes` 派生 artifact 层 max/target(75%) 权重，response 目标保持固定小默认值；
`ResourceCacheCoordinator.updateMaintenancePolicy` 只更新策略，
回收发生在下次 `trim()`（设置页应用后立即触发一次并刷新用量），retained artwork 不受容量整理影响的规则不变。
人类可读的结构化导出目录以 exact `(sourceId, comicId)` 对应的持久化 `DownloadPlacement` 为权威。
物理目录不存在（`!dirExists`）或无真实图片（`!hasRealImages`）且无活跃会话认领时，无条件判定为空闲并释放历史游标，优先分配纯标题目录；
物理存在的非空目录冲突时弹出用户选择，严禁静默重命名或让历史 SQLite 幽灵记录阻断纯标题目录。
冲突恢复/`forcePrompt` 不得只按当前漫画标题重新扫描候选：若当前 exact `(sourceId, comicId)` 已有 persisted `DownloadPlacement`，其 `relativeDirectory` 必须作为 required conflict target 交给同一 storage conflict inspector，即使目录名与标题完全无关、目录/manifest 尚未物化。inspector 可从 manifest 或 durable placement claim 投影 `observedOwnerKey`，UI 只消费该 owner 事实；真正 overwrite 仍由 placement owner 以相同 owner key 重新校验。Presentation 为避免展示 exact/self candidate 可以过滤候选，但必须保留完整 `occupiedDirectoryNames`，因此 `saveAsNew` 的唯一目录分配不能把被过滤掉的 exact occupied 推荐目录重新选中。整本队列/详情页任务查找继续以 `sourceId + comicId` 组合身份为准，相同 raw comicId 的不同来源必须保持独立 job。
任务意图（`DownloadPlacementMode.incremental` / `overwrite` / `createNew`）与落盘目录及 `pageOrder`（`ComicPageOrder.auto/chronological/origin`）持久化于 SQLite `download_placement` 表中，
单章和整本任务都重放同一 placement；仅对升级前缺少 placement 且全部已校验记录唯一指向同一目录的任务，允许从 `CacheRec.path` 一次性迁移。
`pageOrder=auto` 只是一项未解析的导出布局意图：
第一次真实结构化导出前，仅当当前漫画确认为单章且已有 verified `ComicVersionPageMapping` 证明 pure front-prepend 时冻结为 `chronological`，
否则冻结为 `origin`；来源字符串、Venera/E-Hentai 身份或当前总页数均不得作为反序证据。
SQLite schema 6 的稀疏 `export_page_binding` 只为实际进入导出的 `(source, comic, chapter, page)` 保存 immutable `exportOrdinal` 与可更新 logical index；
同 comic 前置追加以及跨 comic 的 verified version chain 都通过既有 binding/compact relation 惰性继承旧 ordinal，
新页只在已用最大 ordinal 后分配，未打开/未导出的中间版本不创建逐页行，因此不得再用全局 `N-index` 重算或推后旧文件名。
普通 Reader 永远按来源 logical manifest 顺序读取，`DownloadPlacement.pageOrder` 不参与 Reader 排序；
只有用户启用 per-comic 设置后的 `invertPageOrder` 是 presentation override。
物理页序改变不是 Reader 行为，现阶段也不存在普通 `flipComicPageOrder` fast path；
未来如需要只能作为显式 Export Relayout migration，在 SQLite generation 与物理 rename/move/materialize 一致提交。
普通下载/重试不枚举目录或收编未索引文件，只消费下载过程中逐页持久化的非空 CRC32 校验记录；`scanExistingPages()` 的唯一生产调用者是显式 `auditChapterFiles()`。该 audit 由当前 `ChapterDownloadService` generation 持有取消 token：先 full-verify 已索引 READY，再扫描结构化目录；未索引图片只有 source-declared CRC32 与本地独立 CRC32（及可用 byteLength）一致时才可走既有 artifact adoption，缺少可比 source proof 时只记为 unproven 而不绑定。Download Manager 只发送 audit/cancel command，Home command owner 保留启动时的 service generation，不把 TaskControl 下放给 Widget。最后一个结构性坏 replica 退出时，SQLite owner 以 zero-replica 条件事务同时撤销 exact READY/physical-media bindings，避免等待下一次 open 才收敛。
最终目标路径提交由唯一 `PersistentDownloadArtifactStore` 串行化：经用户授权的 overwrite 模式允许覆盖更新 `.zic.json`；
同进程已有旧 owner 认领时也必须由 `observedOwnerKey` 精确匹配该 owner 才可替换，未授权冲突抛出显式 `ErrorCode.policy` 错误。
跨版本 createNew 复用必须物化到本版本的 1-based 目标页路径，并在复制前后验证 bytes+CRC32。
结构化页 materialization 的最终图片扩展名 MUST 由 bounded byte-signature sniff 决定而不是来源 hint/文件名；
当前支持 JPEG/PNG/WebP/GIF/BMP/TIFF/ICO/AVIF/HEIF，ISO-BMFF 必须命中明确 AVIF/HEIF brand，generic `ftyp` 不得猜作 AVIF。
已进入结构化图片导出的正文若无任一支持签名 MUST 作为 `artifactCorruption` 拒绝，`ContentKindHint` 不得覆盖实际非图片 bytes。
每个目录的 `.zic.json` 描述当前 owner、稳定章节目录映射、单调 generation 与内容 fingerprint，placement 镜像最近提交 token；
POSIX 继续通过目录锁串行提交。SAF manifest 由 structured placement owner 在任何 SAF mutation 前先 flush App-private transaction intent，再以 deterministic `.zic.json.zic-old` + `DownloadPlacement` commit point 做 recoverable replace/delete；恢复只接受 intent 或 legacy backup 的 exact token 证据，禁止按“target generation 更高”猜测 forward。该协议位于唯一 metadata process owner 内并按 exact manifest path 串行，见 ADR 0342。
page/partial SAF body 不再调用 provider-level overwrite。ADR 0343 规定先完整 staging，再 flush App-private body intent，以 deterministic `target.zic-old` 保留旧正文，并以现有 `CacheRec` / `PhysicalPartialRecord` 的精确新记录作为唯一 commit point；启动恢复只枚举本地 intent 并 probe 其中的 exact SAF path。重存相同 partial 时旧 index 已可匹配预期 authority，因此 target 缺失但 backup 的完整 length+CRC 匹配该 authority 时恢复 backup，不增加 commit token。stale/crash intent 恢复独立读取完整 CRC，未知 target 或不匹配 backup 保留证据并拒绝恢复；正常 live staging/index commit 的清理复用本次累计的 copy proof，不额外扫描 partial 正文。manifest/placement 仍由 ADR 0342 独立治理，两种事务不得共享 commit token。
整本队列把执行期 `ErrorCode.policy` 提升为持久化 `requiresUserAction` 阶段，保存冲突目录、existing/request owner 和触发章节，停止后续调度；
详情页再次发起整本下载时必须重新弹出冲突对比并以新 placement 重建任务，管理页不得把该阶段当普通失败直接重试。
长期数据模型仍需进一步把物理 artifact、逻辑版本 binding 与 export binding 彻底解耦。

### 11.1 当前生产代码的 key/id 对照
整本下载重新形成 placement 时，目录、模式与 observed owner 作为一组整体替换旧任务授权；`createNew` 因此可以明确清空旧 owner，避免重试再次携带旧版本的覆盖许可。

以下是现有实现中容易被混称为“key”的几组身份。它们的用途不同，不能用标题、显示名或图片 URL 互相替代。

| 名称 | 所有者/含义 | 当前组成和用途 |
| --- | --- | --- |
| `sourceId` | 来源身份 | 插件/来源的稳定 ID，不是来源显示名；参与 source namespace、漫画 namespace、`ContentId` 和资源请求绑定。 |
| raw `comicId` | 来源原生 runtime locator | `Comic`、`SavedComicRecord`、`LibraryComic` 与章节归属保留的原始漫画定位值。Mihon 可把可变 SManga 快照编码进该值，因此它只保证“如何再次调用插件”，不得假定为 durable artwork identity。 |
| `LibraryComic.identity` / Flutter comic key | 书架实体身份 | 当前为 `sourceId\u0000comicId`（UI key 再加各自前缀）；标题、作者和封面 URL 都不参与。两个同名漫画只有在这组身份也相同才会被视为同一个实体。 |
| `canonicalComicId` | 来源确认的稳定同源身份 | 由来源从 raw locator 投影的稳定等价值，用于冷书架归并和 durable comic/artwork namespace；不得替换插件请求、章节或 Reader `ContentId` 中的 raw `comicId`。Mihon 当前以规范化漫画 Web URL投影 canonical identity。 |
| `chapterId` | 来源原生章节身份 | `Chapter`/`ChapterManifest` 的章节身份；章节元数据响应 key 使用 `[sourceId, chapterId]`，并挂到已知漫画 namespace。 |
| 详情/来源页章节 Flutter key | 章节行的 presentation identity | `sourceChapterKey` 与 `comicDetailsChapterKey` 必须保持同一字面值 `source-chapter:${sourceId}\u0000${chapterId}`；已读滑动容器和下载按钮分别使用 `chapter-read:${sourceId}\u0000${chapterId}` 与 `chapter-download:${sourceId}\u0000${chapterId}`。这些是 UI key，不是 metadata response cache key。右划切换已读/未读，左划露出最右侧删除按钮并由点击触发删除；长按已缓存行打开确认框。 |
| `pageId` / `PageAsset.assetKey` | 章节内页面身份 | `PageAsset` 保留 `pageId` 和 `chapterId`，`assetKey` 为 `chapterId/pageId`；它不是封面/预览响应缓存 key。 |
| `ContentId` | Reader 内容实体身份 | `[sourceId, comicId, chapterId, pageId]`，用于确定一个漫画章节页面；`ContentId.key` 只服务 Reader/download identity。 |
| `DownloadId` | 确定字节版本 | `ContentId + sourceRevision + canonicalUri`，用于 Reader 下载/artifact；页面 URL 变化或来源版本变化会形成新的确定字节身份。 |
| `VersionFamilyId` | 同源版本族 control-plane 身份 | 来源确认的 opaque 稳定 family namespace；只用于 exact chapter→canonical segment 投影和关系收口，不替换 raw `comicId`、`DownloadId`、provider URI 或 validator owner。 |
| `PhysicalMediaId` | 物理 transfer/cache owner 身份 | exact fallback 或 verified canonical coordinate。canonical 只由 direct verified projection 发布；mutable partial/READY 可按此键跨版本共享，而 provider validator、manual pin/export 继续属于 exact `DownloadId`。 |
| `DecodeId` | 解码输出身份 | `DownloadId + physicalWidth + physicalHeight + pixelFormat + renderer`；不参与首页/详情的图片响应缓存。 |
| `ResourceCacheKey` | 响应缓存实体身份 | 四元组 `kind + identity + namespace + revision`；四项都参与 equality/hash。图片使用 `kind=imageBytes`，详情/章节/搜索分别使用对应 response kind。 |
| `coverUri` / `coverSourceId` | 图片 locator | 只告诉 artwork gateway 去哪里取图；可能是 HTTP(S)、`mihon:resource:` 或本地 locator，本身不参与稳定漫画身份。外部封面响应使用 `[sourceId, canonicalComicId, role=cover]`，URL变化不会分裂 namespace。 |
| `previewUri` | 预览项 locator 和绘制身份 | 详情预览完整 URI（包括 Venera `@x/y` 裁剪后缀）保留在预览项、widget 和 painter 中；编码字节缓存及实际请求使用去掉 `@x/y` 的 base URI。 |
| `resourceRole` | 漫画图片角色 | 封面为 `cover`；详情预览为 `preview:<base previewUri>`；其他带 URI 的 artwork 角色同样使用 base URI。外部 artwork 响应 key 使用 source + canonical comic identity + role；raw comic ID 只传给 runtime loader。 |

### 11.2 同源版本与迁移身份

同源版本必须区分以下身份，任何一层都不得用标题或 URL 字符串替代：

- **raw locator identity**：`sourceId + raw comicId`，是插件请求、SavedComic、章节归属和迁移前后实体的真实定位身份；
  同一来源的新旧版本必须保留不同 raw comicId。
- **canonical comparison identity**：来源确认的同源等价比较值，只用于归并重复投影和比较候选；它不能替换 raw locator，也不能直接改写章节、页面或下载 key。
- **version relation identity**：`sourceId + predecessorComicId + successorComicId`。
  关系必须由 `ComicVersionSource` 或已持久化的来源确认结果产生；标题搜索结果不能自动成为版本关系。
- **chapter/page identity**：
  章节始终为 `sourceId + chapterId`，Reader 页面为 `sourceId + comicId + chapterId + pageId`。
  迁移比较的 `exact` confidence 表示章节序号与归一化标题同时匹配，不能替换上述原生 identity。执行器在写入前重新取得并校验目标 `sourceId + comicId + chapterId`，再复制阅读进度和已读状态；**sequence-only** 匹配仅显示在比较报告中，不复制状态。
  metadata correspondence 不证明页面内容相同；artifact 复用独立要求 `VerifiedArtifactReusePlan` 的 media proof，保持目标 exact binding 与来源 offline retention 各自独立。
- **presentation identity**：Flutter key、详情提示和 Reader 一次性提醒只能引用上述稳定复合身份；
  Widget key、当前章节、封面 URL、按钮状态和 runtime adapter 对象都不是持久身份。

同源 successor 发现后写入 `ComicVersionRelationStore`；`HomeLibrarySession` 在 enrichment 时一次加载全部 relation，
并在新 relation 写入时同步更新内存投影，因此 Home/source browser 无需依赖详情页副作用即可判断旧版更新。
source-card `!`按relation predecessor/successor的raw+canonical identity区分，
不能因library alias归并吞掉predecessor或在successor误报。详情页multiple versions先选择；详情/version-state与Reader都可异步检查版本。
显式查看版本时，目标详情route持有`originComicId + reuse-preparation Future`直到该target route退出，
不能因前置Future先完成就丢失selected-version上下文；目标Reader hydrate当前chapter后、创建physical demand前先等待前置Future，
再只针对`origin ↔ target` direct relation做一次target-side bounded catch-up。generic Reader不等待这条barrier，也不扫描历史。
proof形成后`HomeLibrarySession`把exact version page的verified interval编译为compact canonical projection；
落入projection的`DownloadId`在session创建前直接解析为版本无关`PhysicalMediaId`，目标版本新增/未验证区间保持exact-only。
Reader启动后继续异步metadata/version refresh；
既有pre-canonical physical generation可由兼容alias自然退休，但新hot-path不再通过版本carrier ranking定义physical identity。
cross-version cold durable state仍只在physical prepare的durable tier参与恢复，
provider request/validator继续由每个claim的exact `DownloadId`拥有。确认迁移后只复制library实体状态；媒体artifact不做hard alias/rekey。
同漫画多版本的 durable relation store 是历史证据层，不是运行时选择器。
`HomeLibrarySession` 在 relation/shelf preference/manual snapshot 变化时重算 `latestKnownHead / shelfHead / downloadHead`，
并把唯一可证明的历史路径折叠成 direct predecessor→downloadHead mapping 后只注入 manual/export 子路径；
artifact cache 同时独立接收完整 source-verified relation 集，绝不因 downloadHead/是否显式下载而丢失 cache reuse。
DownloadManager、ExportLayout 和章节下载执行不得自行 BFS/求传递闭包。不同版本 chapterId 只有折叠后的 `pageMappings` 明确对应时才归并；
direct baseline relation 缺 mapping 的 legacy 情况才允许 same raw chapterId 兼容。当前 Presentation 不建立旧版子项树；
被 downloadHead 取代的旧手动 row 只从主列表投影隐藏，其 exact durable placement/artifact 与删除 authority 仍保留。
source 新版只成为 `latestKnownHead`，必须经过书架迁移或显式下载后才分别成为 shelf/download head。

### 11.3 Artwork 身份与呈现

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

图片加载失败的边界必须分开：cache hit/miss 只说明编码字节是否存在；source loader 的失效路径、非图片响应、权限/challenge/空响应由 gateway 拒绝；
Flutter decode 错误只影响 presentation。
来源列表的既有 canonical card Future 保留成功或失败结果，Sliver 重新挂载不重发失败请求。
SourceBrowser 只记录当前 Future 的 decode 失败观察；显式来源刷新退休目标来源的 Future，
将失败项的一次性 `forceRefresh` 命令经 `SourceComicCoverLoader` 与 Home composition 交给 gateway。
gateway/ResourceCacheManager 在原 canonical key 上替换该响应，健康项继续正常 cache probe；普通 rebuild、
来源切换和迟到的旧 Future 回调不能生成刷新命令。聚合刷新同样只针对当前选中的来源。
`StableArtworkImage` 以实际 provider 等值身份保持内部 Image State；不同 provider 退休旧 State，
防止上一代解码错误在新首帧等待期间被归到新资源。该呈现边界不拥有 encoded 字节、缓存失效或重试。
普通 browse 在现有查询投影边界按来源 canonical identity保留首条 summary；cached/refreshed比较同一投影，不在逐帧builder归并。
显示去重不改变来源分页：显式nextOffset优先，fallback使用原始条目数；raw locator继续归来源命令与资源请求。
既有来源view保存已接纳的访问坐标与不可变快照；上一页使用真实前一坐标，页序号按访问路径展示。
来源往返按恢复页码重载，缓存恢复同样归并；发现section/filter改变请求分区时回到0并重置路径。
访问路径只承载UI导航意图，随query/filter/section/page0重置；source/runtime/cache/transport仍拥有原分页与数据authority。
单张失败的 Trace 至少记录脱敏 `sourceId/raw comicId/resourceRole/URI`、cache origin 和 transport/decode 错误，不能仅凭占位图判断缓存冲突。

### Reader checkpoint 与历史投影边界
Reader 页面变化只 enqueue 最新 `ReadingProgress`，不得等待 SQLite或逐页发布 Home；首次
checkpoint 写入前不创建 progress writer，首次写入后 storage isolate 对同 source/chapter
latest-wins，空闲约 8 秒提交、持续活跃最多约 30 秒提交。`ReaderProgressCheckpointStore` 同时暴露 route/lifecycle 专用 durable flush；
Reader 正常返回前必须在最终 checkpoint drain 后等待该 barrier，background lifecycle也发起同一 barrier，而普通页面变化仍不等待。
Reader 返回后 Home只更新该 route最终 progress一次，已挂载详情只替换当前章节；不得在返回路径读取/重建整库。
硬进程终止在 flush barrier 之前仍为 best-effort，不宣称最后一页绝对持久化。

## 12. 插件与网络边界
- Venera 的单 JavaScript invocation context 是 external-runtime 的串行执行资源，不是第二套 Reader scheduler。
  带同一 `TaskControl` 的 page request-plan 在进入该唯一 context 时继续服从 NetLane 实时 priority：
  当 priority 达到 controlled pressure floor（当前 780）而 active invocation 是无 `TaskControl` 的普通后台调用时，
  runtime gate 可以请求取消该 generic invocation；若 active 本身受控则仍遵守既有 rank 差/preemption 规则。
  取消只请求下层尽快退出，唯一 permit 必须等旧 invocation 的 physical Future/`finished(requestId)` 真正结束后才能转交，不得为抢占增加第二 context。
  `Network.*` async bridge waiter 必须记录所属 `requestId`；`__zicCancel(requestId)` 除取消resolver I/O与delay waiter外，
  还必须同步移除并reject该request的JS bridge waiter，使正在`await Network.*`的source hook立即unwind。
  迟到native bridge回包在waiter已移除后只能丢弃；唯一invocation permit必须等JS `finished(requestId)`与已接纳native work退出齐备后归还。
  Native driver关闭先封admission，再以`closeWhenDrained`等待同步bridge、原executor work和isolated图片primitive物理退出；之后才回收图片/输入、销毁WebView并返回pending关闭结果。
  `NativeExternalPluginDriverHost`保留原driver登记到关闭回执，重复关闭join同一Future；已接纳activation的晚到driver也必须退休。无新增executor、FIFO、并发槽、retry或网络资格。
  isolated Service保留FlutterEngine/resolver回调到native关闭完成；Main不阻塞等待。原IPC executor依次drain读取、回包及回调提交的cleanup后再清packet store并shutdown。
  Reader 首帧后的 metadata/version refresh 属于可被这种 foreground pressure 让行的后台调用。
  `sourcePlanGateBlockedBy*` 只记录 waiter 首次入队时看到的 blocker，用于归因，不代表整个 gate-wait 区间始终由该 operation 占用。
  Source metadata 瞬时 JSON parse 恢复也属于该 external-runtime 边界：
  只读 Venera source invocation 仅在本次实际发生 bridge network call 后抛 `SyntaxError` 时可用同一 `TaskControl` 做一次 `freshNetwork` replay；
  fresh 必须 bypass runtime HTTP cache，第二次失败即终止。
  `Cache-Control: no-store` 响应还必须撤销同 URL 的 memory/persistent runtime cache entry；Reader/UI 不得增加 retry owner。
- 下载、解码、上传使用独立 scheduler；一个层的运行时状态不能成为另一层页面的资格门控。但一次accepted `DemandPlan`属于跨三lane的控制面事务：
  所有diff/liveness mutation完成前不得反复pump intermediate state，outer reconcile提交后每个lane最多以最终state执行一次必要pump。
网络默认 User-Agent 属于 composition-owned 请求策略。AppPreferences 保存当前 fallback UA，默认使用稳定 Android Chrome UA；
`main`/composition 以动态 provider 注入通用 `HttpTransport`、
Reader/章节下载 fallback、插件仓库 control-plane 与 shared source host transport。
来源 request plan 显式 `User-Agent`、Mihon browser-session UA或 source-owned client策略拥有更高优先级，全球设置不得覆盖这些来源权威。
Presentation 不得自行构造 HTTP client。

网络执行只有三类合法 owner：
- **source-owned client**：Mihon/Venera 等来源的 CookieJar/interceptor/auth/DNS/TLS/session 语义；
  Android隔离runtime service在engine/driver启动前以宿主applicationContext初始化canonical OkHttp，保证域名/Cookie资源可用；主进程AndroidX Startup不能替代该进程初始化，扩展payload Context不承担此平台职责。
  未知 client wrapper、重定向、`Set-Cookie` 或无法无状态平铺的响应必须留在这里执行；
  Mihon/network bridge 的 `FallbackDns` 先完整尊重系统 DNS 的非空返回顺序（包括合法 split-DNS/private 地址），不得再强制 IPv4 前置；
  仅当系统 DNS 失败或为空时才进入 public fallback，并同时查询 A/AAAA，以交错双栈结果返回，不得把 public-address 过滤反向施加到系统 DNS authority。
  Venera JavaScript `Network.*` 的 Cookie、manual redirect、
  `cache-time`、`prevent-parallel`、requestId grouping 与同步 JS contract 仍由 plugin-host source runtime拥有；
  其中 Venera source-requested resolver cache 属于runtime-network composition，
  `NativeExternalPluginDriverHost`持有唯一有界`VeneraHttpCacheStore`并以`pluginId/pluginVersion/sourceKey`分区，
  单个WebView/`VeneraNativeBridge`只消费而不得拥有或在close时清空，同namespace bridge replacement可继续复用仍新鲜的resolver entry。
  显式用户resource fresh generation是这个复用边界的例外：
  `fresh:true`重新执行source hook时，只给该hook实际发出的`Network.*`调用附加request-scoped fresh语义，
  由同一cache owner逐URL force-miss并以新origin response重新填充；
  不做source namespace级清空，也不把fresh resolver行为变成新的retry owner。
  HTTP execution 不再由 Kotlin `HttpURLConnection`/DoH/reflective OkHttp拥有；
  isolated plugin Dart process 持有 reusable rhttp/reqwest resolver client 与 requestId→CancelToken 映射。
  该client未配置自定义DNS，解析使用rhttp默认系统DNS；requestId cancel经原MethodChannel取消对应HTTP及正文读取，原call结果返回并完成native finally后才退休。
  默认reqwest GaiResolver使用Tokio blocking getaddrinfo；HTTP Future取消不证明该系统解析已退出，不能据此关闭DNS物理退出验收或增加独立DNS owner。
  resolver rhttp 的 transport failure 必须以typed retryability跨 Dart MethodChannel→Kotlin bridge→WebView JS runtime 保留，
  不能退化成字符串后靠错误文案正则重新猜测；
  `venera-resolver-http-failed` 属于network failure并继续交给既有physical `DownloadTransferOwner`/provider `RetryPolicy`，
  bridge/runtime自身不得因此新增第二retry loop。最终 media replay继续由主流程的 rhttp direct transport执行。
  canonical bridge在原executor提交前登记request-scoped native call，物理finally退出后退休；JS `finished`与native call退出分别记录，两者齐备才转发原result/完成。
  取消标记保持到该边界，迟到result不发布，native-byte token只按被取消request清理；bridge完成登记不持executor、FIFO、retry或priority policy。
  由于两者位于不同进程，不能共享同一物理client/连接池，但必须统一到同一 rhttp client family；Kotlin/WebView不得重新建立第二HTTP connection pool。
  协商过body delivery的Mihon自定义client由原source invocation把response stream写成有界raw body；`RuntimeServicePacketFiles`继续拥有临时文件，`.packet`仍是codec envelope。
  同一body交易也接纳同步编码器写入借用的有界OutputStream；InputStream入口委托它。owner在producer返回后关闭stream，再封存并发布相同length/SHA/FNV/prefix；被producer捕获的写入失败仍阻止发布。该入口没有额外队列或文件owner。
  body reference绑定driver/request/source/runtime/payload及原locator，携带length/SHA-256/旧FNV validator/最多64B prefix，不能接受调用方文件路径。
  host packet owner先原子claim为`.lease`保护物理读取，再在原response executor做可取消校验，成功后才发布；`ExternalPluginRuntimeFileBody`持一个handle，异步有界读取，dispose先等已接纳read退出再close/release。
  source descriptor与connection必须同时声明能力；`SourceResourceTransport`才把它投影为原staged/source `ByteResponse`，保留image admission、validator与Range语义。
  unclaimed正文归原packet/driver清理；claimed正文在source进程退出后仍由consumer释放，新host进程清掉上一host进程遗留lease，同进程client共用清理identity。
  runtime close封新admission并排空晚到response/claim/read/release，正文登记直到release回执后才退休；NetLane task仍持有完整消费生命周期。临时路径不进入locator、DownloadId、artifact、信任或Reader，聚合与promotion仍归DownloadJob/DownloadSession。
  Android caller仅在API29+系统Trace启用时观测原client执行、正文read/seal及host claim；固定label不含请求身份，关闭时直接使用原InputStream。纯文件owner不依赖Android tracing，重叠seal/read不得重复归因。
  Venera的transform output能力独立于loadResource，仍需source descriptor与connection共同声明；输入保持完整，onResponse和canonical JavaScript语义不变。
  isolated-qualified modifyImage由原2-worker在physical encode内直接写入同一body交易；canonical结果仍经原JavaScript完整字节后封存。输出reference绑定venera-runtime-transform-v1与payload，host只接受已协商transformResource。
  SourceResourceTransport对两类sealed body共用原image/Range/validator与dispose合同；file输出只替代跨进程正文载体，不改变locator/cache/trust。取消、关闭及替换completion均清理未交付body。
  sealed交付等待来源正文完成；host输入聚合、canonical完整字节和未协商来源保留原契约，实时网络stream/pipe不由该能力证明。
- **统一 host transport**：仅重放来源已经解析成无状态 request plan 的单次资源请求。

  生产 Flutter composition由 `downloads_bridge` 注入可取消的 Rust/rhttp streaming transport并复用client/keep-alive；
  rangeStart=0 的完整/首段response通过媒体前缀校验后保持raw streaming cadence，
  合法206且`Content-Range.start > 0`的中段不得再次要求完整图片magic header，应直接保持raw stream/cancellation/diagnostics；
  不得仅因中段不含文件头而转runtime fallback，也不再建立第二套64/256KiB framing。
  transport packet边界由 `DownloadJob` 统一聚合为首批约16KiB、后续64KiB source-progress quantum后才进入session/native/artifact；
  pure `downloads` 的 Dart HttpClient只作为非Flutter/test默认。
  两者都关闭自动redirect，只有无 Cookie状态变化且直接返回编码媒体时才有资格把字节交给 Pipeline，且平台 transport必须观察同一个 `TaskControl`。
  rhttp持续传输观测只允许通过`ByteResponseReadDiagnostics`在stream结束/取消时snapshot receive-progress与raw-body cadence；
  当前rhttp的receive-progress由Dart响应stream的onData回调产生并限频20ms，不是独立socket/Rust接收时钟。
  consumerPacing及body-read permit停驻会影响这些间隔；共同长gap不能单独证明源/CDN慢，需先对齐实际读取与停驻区间。
  HTTP version和匿名endpoint hash仅用于trace。
  该seam不得提供pause/resume、bandwidth quota或priority，也不得进入Reader/Pipeline/session policy；
  Venera source 的图片正文还有一层独立于transport retry的source semantic contract；
  该能力只属于host-private image binary seam，public `Network.fetchBinary/http_binary`继续允许任意binary：
  rangeStart=0的2xx正文若在image-private native/runtime边界已证明不具备受支持图片magic signature，
  必须在注册native-byte token/交给Dart之前判为image-load failure并失效该URL的runtime HTTP cache。
  host direct/rhttp把这一事实标成`sourceMediaSemanticRejected`；普通 `IoTransport` 本身仍只传 bytes，但进入 composition image `DownloadJob` 后同样用 generation-local prefix 产生这一 semantic rejection，因此 direct URL 与 opaque plugin resource 在 transfer owner 处共享同一无效正文退休规则，而 transport 不形成第二 content owner。
  `SourceResourceTransport`由单一source-recovery owner在一次logical open内最多消费5个当前config的`retryResource/onLoadFailed` replacement，
  而不是因笼统`sourceMediaProtocolMismatch`把原locator送入full-runtime，也不得让provider RetryPolicy另起semantic retry层。
  `sourceClientStateRequired`才表示redirect/Cookie/interceptor/session state必须交给source-owned runtime client。
  Venera retained config以`semanticRetryCount`共享streaming与full-runtime剩余预算：
  replacement自己的`onLoadFailed`可继续生成下一config，达到5次或无callback才转non-retryable `ErrorCode.source`；
  同一retained logical resource不得fresh-resolve原`onImageLoad`逃逸该预算。
- **control-plane HTTP**：插件仓库索引/APK/JS安装等，不属于漫画 response cache，但仍使用 composition 的默认 UA fallback。
Venera 的 canonical source WebView 继续是唯一 stateful JavaScript invocation context，保持单 invocation；
不能为了图片变换吞吐把整个 source runtime 并发调高。source request plan 若显式导出可隔离的纯 `modifyImage`，且脚本不依赖 `onResponse`、
source/browser/network 可变状态，则可进入独立 image-only transform context；
该 context 不加载 source script，只暴露 `Image` bitmap primitive，不拥有 `Network`、Cookie、settings 或 source data。
image-only plane MAY 使用最多 2 个 bounded worker 以重叠独立页面的 decode/bitmap transform/encode；
isolated输出编码借用native host既有executor，避免占用WebViews共享的JavascriptInterface线程；不新增池或排队/admission owner。
JS只在编码物理退出回执后disposeAll并finished；原worker capacity、pending completion与body discard owner保持到该边界。
原NativeRuntimeWorkDrain在executor提交前登记编码，退出后退休；close等待编码再回收Bitmap，transform不关闭借用的host executor。
每个 worker MUST 独占自己的 WebView 与 Bitmap namespace，request-local `disposeAll` 不得作用于其它 worker。
Dart transform gate 与 native worker capacity MUST 一致，不能靠第二 scheduler 或无界 native queue 扩吞吐。
静态资格不成立或运行时发现缺失 source global 时返回 incompatible 并重新经过 canonical source gate；
`onResponse` 始终只在 canonical context 执行。image-only context 因此是 CPU transform execution plane，
不是第二个 source owner，也不得在 transform gate 下偷偷调用 canonical WebView。
Reader 首个 presentation frame 后的 metadata/version/reuse warmup 属于 application background source work，
不再由 first-frame callback 直接发起无优先级 source invocation；生产实现把整条 refresh（comic/chapter metadata、version discovery、
version-reuse warmup 以及其 verified-reuse resolver probe）作为 priority 100 任务提交到 application-level `DownloadResourceCoordinator.networkLane`，
同一个 scheduler `TaskControl` 经过 `ControlledComicSource` / `ControlledComicVersionSource`、
`CachedBrowsableComicSource`、plugin runtime adapter 与 `SourceResourceTransport.verifiedReuseIdentity` 一直传到底层。
受控 warmup 不得 join 一个没有该 token 的 generic coalesced Future，否则会重新丢失 cancellation/priority owner；
前台 page-plan 仍使用既有更高 rank，并可由同一 NetLane/runtime gate 让后台 metadata 退出，
Venera 唯一 permit 仍必须等被取消 invocation 真实结束后才能转交。这里没有 Reader 私有 timer、metadata lane 或第二 scheduler。
`ResourceCacheManager` 是可重新获取 metadata/artwork response 的唯一缓存 owner。
Catalog browse/details/preview/comment/chapter 只管理 metadata，
`CachedBrowsableComicSource` 不提供 artwork loader facade；封面、预览不得直接取得 raw source transport。
章节正文/Reader page body 明确由 DownloadSession/artifact/Pipeline 管理，
因此通过 `ComicSourceResourceGateway.pageResponseLoaderFor/loadPageBytes` 绕过 response cache。
两者必须复用同一 source-resolved response loader；full-byte fallback不得直接调用 `source.loadResource()`。
章节下载侧只接受原子 `ChapterResourceAccess`，不得分别更新 byte loader 与 streaming transport。

插件先生成 request plan。GET/HEAD 必须零 body且不得携带实体 headers。
Mihon 页面资源必须从 `HttpSource.imageRequest(page)`（或等价 source request）保留准确 URL、method、headers和必要的小型 request body；
共享 transport不得注入 Venera专用默认 UA。
Android宿主必须提供可执行 source实际返回 HTTP(S)媒体 URL 的统一网络能力，不能按具体插件/域名维护 cleartext白名单或擅自 HTTPS改写；
URL选择仍属于 source/request plan。宿主直连前同步投影当前 source OkHttp CookieJar Cookie与同站点 browser-session UA。
`AndroidCookieJar`在原适配器内按domain/name/path保存完整HTTP响应Cookie，按有效期与URL匹配读取；同名不同path保持独立，长path优先。
请求domain/path范围内已知Cookie的Secure、有效期与删除不能被异步CookieManager镜像覆盖；另一path的同名Cookie不屏蔽请求URL上的未知镜像Cookie。镜像header不带属性，同名且范围重叠的未知身份不能完整还原。浏览器name/value快照沿既有host与revision导入，不另建Cookie或会话owner。
若宿主 HTTP成功但响应前缀不是支持的编码图片，字节不得进入 Pipeline/decoder；
这属于source image semantic rejection，应由同一个source-recovery owner按当前config的`retryResource/onLoadFailed`有界推进replacement chain，
而不是把同一原URL转入runtime重放或让provider retry重复消费semantic recovery。
只有宿主无法保留source client state时才使用source-owned runtime network兼容路径；
普通可重放图片仍由宿主流式 transport进入统一 Pipeline，完整图片正文不得仅因 Cookie/header需求改走 JSON/Base64 RPC。
页面下载的 retry只有 `LiveCoordinator` 一个 owner：runtime transient错误必须投影为 `ErrorCode.network`后进入有界重试；
非 retryable/source错误或重试耗尽在当前 demand内成为 terminal，source listener/finally不得自行重复提交。

可见浏览器 Activity 与 Cookie/localStorage/UA snapshot 只由 `network_bridge` 声明和拥有；`plugin_host_bridge` 仅消费共享网络 runtime helper，不保留独立登录 Activity 或快照存储。
Cloudflare 可见浏览器的 Cookie 与 User-Agent 必须属于同一个浏览器 session。
验证模式下 `NetworkBrowserActivity` 不得把插件/OkHttp 的静态 UA 写入 WebView；
WebView 使用当前 Android WebView provider 的真实 UA，并把该 UA 与同站点 Cookie/localStorage 写入同一 snapshot revision。
`NetworkBrowserActivity` 在每次导航开始时撤销 capture readiness；普通页面完成加载后才允许 capture，验证页面另须通过原同站点、完整加载及无 challenge 的稳定窗口。
验证探针的 ready/challenge 结果均为 Boolean，Kotlin 按同一类型读取；无效结果继续保守等待。
立即返回或 Activity 销毁不能把未完成页面写为新 handoff；迟到 localStorage 回调必须仍属于相同导航和已完成 URL，不能更新后续导航的 snapshot。
成功回执等待 localStorage capture，与 Cookie/UA 在原 snapshot store 一次提交；已结束 Activity 的销毁和异步回调不再补写 revision，避免污染下一次浏览器 handoff。
Android 13+ 的系统返回通过 Activity-owned `OnBackInvokedCallback`，较旧系统通过 `onBackPressed`，共同调用原 WebView 历史导航/完成入口；销毁时撤销回调。已完成普通页返回成功回执，仍等当前 capture 提交；未完成验证保持失败，不能由系统默认关闭绕过此裁决。
Mihon runtime 读取 snapshot 时不再要求它等于启动前的静态 UA，而是在 OkHttp application interceptor 中对同站点请求逐请求采用 snapshot UA；
CookieJar 同步导入同一 revision 的 Cookie。
这样避免 `cf_clearance` 来自真实 WebView、HTTP 请求却继续声明另一浏览器/平台所产生的 Cloudflare 指纹不一致。

`sourceVerificationRequired` 只由 host-owned typed `SourceVerificationRequiredException` 产生。
`cf-mitigated: challenge` 是明确协议证据；
否则 HTTP 状态必须为 403/503、`Server` 必须是 Cloudflare，并且 HTML 必须含 Mihon 同样使用的 `challenge-error-title` 或 `challenge-error-text` 实际交互 challenge DOM。
仅出现 `challenge-platform`、`cf-chl-*`、`Just a moment`、
Cloudflare Server header或普通 403/503都不足以触发浏览器验证，避免把 geo/access block误分类为可通过 WebView解决的验证码。
异常 envelope 同时携带实际失败 request URL、HTTP 状态和请求时 `cf_clearance` 是否存在；这些字段只用于恢复路由和诊断，不进入持久 identity。
Mihon 主网络和 ABI兼容 interceptor均委托同一个 detector；不得创建隐藏 WebView、等待 challenge或按异常消息文本猜测。
插件和平台桥不得导航、创建 Reader、提交 demand、直接读写 artifact、访问 App controller，或把 Cookie/token/Base64 payload 原文写入 Trace。
## 13. Telemetry 与关闭
- 创建者关闭 owned 对象；外部注入能力不得被消费方误关闭。
状态所有者产生权威事件；App 只做有界导出。Debug Trace 的文件落盘由单一 App export service 拥有：
它统一 snapshot、JSONL 编码、文件名和目标目录，首页快捷入口与 Trace 页仅提供不同事件集合。
目录策略由纯 App destination model 拥有并持久化为 `Download/` 下的相对子目录，默认 `Debug`；
Android bridge 使用 MediaStore 写 `Download/<relative>/` 并只做最终路径安全复验，不能形成第二套目录策略。
composition physical transfer事件对共享App/export sink只能写一次；
每Reader可保留独立memory trace projection，但不得经多个Reader wrapper把同一physical event重复写入同一全局sink。
跨 Home/Details/SourceBrowser/Reader/Pipeline 的 `TraceEvent.monotonicMicros` 必须来自同一 process-monotonic `SystemClock` epoch；
route-local stopwatch只允许计算局部 duration，不能作为可跨组件排序的事件时钟。
physical DownloadSession 的trace identity跟随physical owner token而不是偶然exact anchor；
长 decode/upload/provider identity可由owner一次性生成与`TraceEvent`脱敏规则完全一致的稳定token并复用。长 identity 使用 hash/长度摘要；
导出投影可按稳定语义桶合并高频诊断样本，例如 `framePipelineTiming` 按 trace reason / dominant stage / role，
`decodeRefill` 按 role / stage / source-wake 分桶，并保留 first/last、count 与关键 timing/source revision 的 min/max。
该合并只属于导出观测，不改变运行时事件或策略；错误、retry、writer rejection、resume/source read、session retain/reuse 和生命周期边缘不得因导出压缩丢失。
overlapping total 不得与子阶段重复参与 dominant 归因。production rhttp 的HTTP version与匿名endpoint hash属于每response低开销观测；
高频Dart stream receive-progress只允许non-product或显式诊断构建启用，且不得改变transport cadence或成为调度输入。
完整关闭遵循依赖逆序：停止新 demand，关闭 upload/decode/download，释放 frame/output/texture，
关闭 runtime scheduler与 workspace，最后由 App 关闭其创建的平台 facade。外部注入 capability 不由消费方关闭。
## 14. 静态门禁
静态门禁阻止明显的依赖反转、API 泄漏、重复权威和文档漂移，但不能替代 `flutter analyze`、
Dart/Flutter/Rust tests、Android debug/release build 和真机生命周期/性能验证。
Detailed download/storage ownership for multi-version materialization,
SAF/direct coexistence, partial transfer continuity and Reader/manual resource sharing is defined in [`DOWNLOAD_STORAGE_ARCHITECTURE.md`](DOWNLOAD_STORAGE_ARCHITECTURE.md),
with normative rules in [`DOWNLOAD_STORAGE_SPEC.md`](DOWNLOAD_STORAGE_SPEC.md).
The production decomposition is `VersionHistory/VersionBaselineResolver + ArtifactRepository + StorageRootRegistry + ExportLayout + TransferCoordinator + StorageCoordinator + AppResourceCoordinator`;
Pipeline remains Reader-specific and consumes shared capabilities rather than owning application-wide network/storage policy.
Durable chapter metadata is App-private `chapter_downloads.sqlite` with one-time validated legacy `cache.sqlite` import.
Schema 7 owns persistent root/access identity and health;
proven Direct/SAF locators for one system ExternalStorageProvider root are aliases whether the tree is `primary:` or a uniquely resolved current `StorageVolume.uuid`.
UUID/path mapping is only candidate discovery and never root authority:
the existing bidirectional canary remains mandatory,
same-SAF reproof after a mount-path change keeps one `StorageRoot`,
newest verified healthy Direct is preferred, and `accessDenied` degrades only that locator.
Schema 8 owns sealed physical copies through `artifact_replica`:
`artifact_object` is immutable proof plus compatibility mirror,
ready v7 objects migrate to stable replica one, partials never become replicas,
and additional copies require exact-length + CRC32 verification.
Reads resolve artifact→replicas→proven aliases;
structural failure retires only that replica, while access/I/O failure preserves it,
and mid-stream fallback never splices independent copies.
The final logical-binding removal cleans all registered replica bytes.
Existing whole-root POSIX migration rewrites replica locator/root while preserving `replica_id`.
Schema 9 persists progress-only `artifact_replica_migration` state for durable sealed-replica relocation;
schema 10 is the migration-completion marker for the chapter-download metadata DB,
so legacy artifact/root/download-identity backfills execute only while upgrading from v1-v9 and MUST NOT rerun on every current-schema open.
during `copying` the source replica remains authority and the deterministic temp is non-authoritative;
after restart, Direct/current-SAF temp bytes resume only from a physically measured length after whole-prefix CRC32 comparison with the sealed source,
while unprovable or mismatching prefixes restart from zero.
Destination length+CRC32 is still fully verified before one SQLite transaction moves the same `replica_id`/compatibility mirrors and marks `cleanupPending`;
failed source/temp cleanup survives restart as debt and never rolls authority back.
StorageRoot alias merges, whole-root byte migration and final logical invalidation keep this progress state coherent.
Automatic lazy convergence/retention policy remains a later boundary.
Root-relative replica persistence is HOLD:current schema-8/9 absolute locators are compatibility mirrors,
while destructive read/delete/migration cleanup now re-resolves the same relative locator through proven StorageRoot aliases after remount;
no schema-17 authority is justified by current evidence.
Removable-volume Direct mapping is closed as access-capability discovery rather than replica-placement policy.
App composition owns three separate cross-consumer resource domains:
shared `NetLane`, shared `ArtifactCacheReadScheduler`, and `StorageWriteScheduler`;
durable relocation consumes the third domain and yields between bounded copy/verification/cleanup quanta while foreground local-read pressure exists.
Persistent streaming Reader reads, UI recovery ownership removal,
typed `ArtifactReadFailure`, Transfer-owned retry,
exact POSIX partial-spool adoption, sparse export ordinals and compact version baselines remain as specified above and in the detailed storage documents.
