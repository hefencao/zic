# Implementation Status
源码版本：0.31.0-dev.328，App build：0.31.0+328
本文件只描述当前源码快照和验证等级。有效需求状态见 docs/IMPLEMENTATION_STATE.json；历史见 CHANGELOG.md，既有证据归档于 docs/archive/。
验证等级：Implemented、Verified-static、Verified-toolchain、Verified-device、Unverified。
## 1. 当前所有权与实现快照

### 调度与传输 (NetLane & Transport)
- 页面网络调度由共享 NetLane 唯一调度：保持 normal 5、current 高优先级保留槽 1。
- 历史阶段演进基线（已合入稳定架构）：dev.192, dev.195, dev.196, dev.197, dev.198, dev.199, dev.200, dev.203 bounded retention, dev.268, dev.269, dev.271。
- 传输并发状态：dev.271 globalRunning 统计受限，支持 active current-class demotion 与 40分 差值抢占。
- 任务排队在 Venera gate wait 期间保持实时优先级感知；响应停驻采用 dev.268 parked-response-eviction 机制。
- dev.269 区分 demanded=true 与闲置流；TaskControl 支持有界 paced drain 与单 invocation 串行保障。
- 外部源传输：VeneraHttpCacheStore 保持 6h 有效期与 targeted force-miss 规约。

### 存储与恢复 (Storage & Ingress)
- 本地准备：设立 physical-local-prepare；普通 local-prepare operation 上限为 max2。ADR 0334 仅允许同一Reader/revision内三个真实viewport-visible、localOnly work使用一个bounded handoff，使operation lifetime暂时达到3；hidden/后台/跨consumer/revision与第四个work仍严格受max2普通槽约束。
- 零拷贝读取：冷启动 cold partial 读取通过 SQLite 索引与文件直接裁决，不向 durable store 随意 materialize durable-store。
- 断点恢复：保持 SourceEpoch、generation 与 frameUploaded / decode/upload 代际一致，提供 recoverable canonical partial。
- 资源会话：支持 media-empty 状态恢复，提供 residentBodyBacked 权威正文与 range hydrate256KiB 预热。
- 元数据权威：由 physical source metadata 提供 generation-local metadataPrefix 保证。
- artwork持久化：retained晋升复用canonical key；已有副本只改元数据，缺失transient副本从未过期内存响应后台补写，不重下或阻塞呈现。ResourceCacheManager独占晋升claim，失效/刷新/clear撤销旧意图。
  58项Home验收通过：持久缓存无勾，单章空心/整本绿实心及入详情清除（031关闭）；23项source-card通过显式精确刷新、健康不重下及provider退休旧错误。033–035/083/108保持；原19/20正文、真实来源与durable损坏开放。
- external-static 状态治理已把 presentation generation 与 raster residency 拆开：Pipeline 保持 same-generation identity，`PipelinePresentationRasterCache`独占 decoded raster residency；
  mounted adapter 在 eviction/revoke 时清掉本地 attempt/provider 并允许 same-identity regrant，detached resident provider 不再被二次 resize/cache wrap。
- 只有携带 exact `storageId + ArtifactCache mutation generation` authority 的 presentation rejection 才允许 `DownloadTransferOwner` 失效 durable body；
  无 authority 的错误不再自动制造新的 presentation/source generation。widget/page-output 的本地异步 fence 已分别命名为 `loadEpoch` / `bindingEpoch`。

### Home 组合与服务代际
- 生产根页面已收口为 `HomeShell` / `home_shell_*`；旧 `DemoHome` 命名只允许出现在历史 ADR/audit 记录，不能再作为当前生产入口或 owner 名称。
- `HomeShell` 只持 Navigator/presentation/composition wiring；library/download/queue authority归`HomeLibrarySession`，其余长期职责归各自Home owner。
- Reader 覆盖态、Download Manager 单实例槽和 comic identity route lock 已进一步抽到纯 Dart `HomeRouteAdmission`；它不持 Navigator/UI 或任一 subsystem authority。 ADR0404：单源页首次挂载先接收已有query，再发原source请求；后续queryRevision与标签路由不变，冷真机queryLength2/offset0已验。
- ADR0399/0400/0401已验保持。0402 Accepted：viewport/DPR/stitch消费原绝对center，DPR首轮接同一layout校正。8先失败、11新合同/105 focused及全门禁通过；Release4bd8351d/PID11582几何28步/真实OS变化16次通过，125完整payload保持。原加载/active视觉/最终显示开放。
- ADR0384 Accepted：完整组合键脱敏保持原始hash/长度，修正507→511假象；不改缓存身份/URI/信任。2219/Rust22/三ABI与普通Release9214事件通过，127长scope/11exact key独立核对。设备上的Mihon扩展行v1.6.0/ABI1.6、下载、五静置slider/四首尾已验收；性能与原加载开放。
- ADR0389 Provisional：旧版缺边先失败，9 owner与2235/Rust22/三ABI通过。普通Release3e65ae94/PID23850匹配51文件，正确Mihon/下载、5静置slider/4首尾跨章含历史覆盖通过；119完整章不变。真实predecessor/提醒输入、原加载与性能开放。
- 自动缓存 projection 进一步收口为 durable inventory only：Reader hot/source-resident session 不再被误计为缓存；本地 `content://` 图册普通读取保持 source-backed、零 artifact write，不会因 Reader session retention 再生成自动缓存项或正文副本。
- 书架管理/批量选择的 managing、batch 与 source-aware identity selection 已收口到纯 Dart `HomeShelfManagement`；删除/移动/归档等真实 mutation 和 dialog 仍留在 UI/既有 owner。
- 显式同源版本查看使用的 `originComicId + reuse-preparation Future` 已从 `HomeShell` 移入 `HomeVersionReuseLifecycle`；UI 只负责 route 前 start / finally finish，Reader preparation 从同一 lifecycle 查询 selected target token。
- durable service generation adoption 已从 Widget State 抽到 `HomeServiceAdoptionCoordinator`：single-flight adoption、同代 cache binding、source-resource rebind 与 source projection commit 在非 UI owner 中完成；dispose 先 fence 新 adoption，再 drain 已接纳工作。

### 外部插件运行时 (Mihon & Venera)
- ADR0400 Accepted：受控先失败确认同步编码堵共享JavaBridge，输出借原executor且退出才dispose/finished，canonical1/isolated2不变。回调6/Binder11/2304/Rust22/native108与六APK已验；真实JM8页runtime≤60.489ms、缓存104读/0重下。0394其余正文、原加载/性能开放。
- 正文寿命：Binder11/Dart9/Source9/PNG6/FailureRetry6/Network4/Cookie8/NativeWebP6/Mihon6及Delay6/PlanPriority6已验保持。089默认GaiResolver的blocking DNS不能由HTTP取消证明退出；VPN旁路受限，TestNetwork成功对照无DNS包，原生回溯需root，仍未验；未改生产。
- ADR0395 Accepted：两有效先失败确认入口回执后晚短页ratio误走top anchor；复用原center/revision，99 Reader及2280/Rust22/108、三ABI通过。Release7ad3a60d三次真冷进入JM保持已保存index3，各11缓存/0下载/失败；slider/首尾与3独立历史覆盖通过。
- ADR0396 Accepted：public显式失效忽略仅touch的recency变化，保留新binding保护与trim/其它完整record比较；受控先失败修复，全门禁/三ABI通过。普通Release单次显式重载仅1预期下载，冷重入11缓存/0重下；未宣称真机强制了touch竞态。
- ADR0397证据保持；融合locator候选76312组等价，但真机288校验仍2592次所选分配，已撤回并恢复原642/Release。保留Unicode/损坏编码2合同测试；候选Profile74/Release99缓存、0下载失败与六静置slider/首尾通过。原加载/固定顿挫、整体GC/输入延迟/最终显示开放。
- ADR0406 Accepted：HTTP响应Cookie保留domain/name/path、有效期/Secure，镜像抑制限定请求domain/path。15契约/真机9断言通过；浏览器属性及同名重叠未知镜像开放。0403/0405异常分类/BOM保持；Reader/NetLane/URI/revision不变，原19/20加载开放。
- 同一扩展 bytecode 的 Injekt请求为`Application`+`Json`；host按Mihon `AppBindings`注入`Json { ignoreUnknownKeys=true; explicitNulls=false }`，并把`Json`纳入common-runtime完整性预检。
- Mihon 新生成的 opaque page locator 现在统一携带稳定 chapter/page replay 坐标；host-direct plan 另带显式 `directPlanReplay`，
  因此过期签名 URL/旧 page plan 可沿既有一次性 source recovery 重取 page list。runtime-transform locator 仍使用 payload-bound v3：
  `mihon-runtime-transform-v3:<payload-sha256>` 并保留 producer payload authority。
  升级前持久化但缺 replay 坐标的普通 `mihon:resource:` locator 会在 Home source-compat gate 判为 legacy 并先刷新 source page list，
  不通过 sourceRevision 换代制造额外版本/缓存 identity。
  v1/v2 均视为 legacy；当前安装 payload 与 persisted v3 revision 不一致也会在 Reader/下载入口先强制 refresh。真实 trace 中旧 locator 的 runtime HTTP 404/source transform failure 会绕过 generic semantic recovery；
  当前修复将这类**非网络** source-owned failure typed 为 plan-replay eligible，而 SSL/EOF 仍由 DownloadJob 网络重试。
  无 replacement、replay source failure 或 replacement 再次同类失败统一收敛为 terminal source-generation handoff；
  Reader 当前页、章节下载命令和 whole-comic queue 只在各自既有 owner 内做一次整章 refresh，网络/verification/cancel 不被误分类。
- 显式 Mihon resource generation refresh 使用 `freshGeneration=true` 重取 page list；runtime 现在按 source+locator 保留 fresh source request authority，而不只是给 Dart 的 plan 投影。
  ordinary replay 的 replacement authority 只供紧随其后的 runtime load 一次性消费，fresh generation authority 则供 resolve/re-resolve/load 共用；实际取图继续走 source client，完整 method/headers/body/interceptor/cookie 不降级。
  source setting mutation 会同步失效该 source 的 retained fresh/replay state；旧/跨 payload 持久 locator 由 Reader/下载入口强制刷新后再消费。
  Android network/Mihon runtime 的 `FallbackDns` 不再强制 IPv4 优先；系统非空 DNS 结果保持原顺序，public fallback 仅在系统失败/空时启动，并同时查询 A/AAAA。
  terminal Reader refresh 仍只由当前失败页触发，fresh chapter matched page carriers按稳定page identity原子换代并保留旧page order，不再单页splice制造同sourceRevision新旧generation混合。
- Mihon原生URL/完整opaque模型共用source调用、URL互斥/canonical artwork，raw响应ID不改。目录response key按raw请求区分，避免比较后历史目录混用父ID。Profile/Release各两轮均41章/已知21页/历史1页、无重复；目标41/精确1/未匹配0/额外40，未确认迁移。
### 渲染与几何 (Pipeline & Reader View)
- 自适应阅读：`reader_runtime` model v8 将页面几何改为一次性小样本判定：最多 3 张且包含第一页；
  `0.65 < h/w < 1.20` 的异常切片比例不形成页漫票，达到样本目标后停止重算，避免 profile 随预加载页数漂移。
  `AppPreferencesController` 按 `sourceId` 唯一持久化 0–1 条漫置信（0=强页漫、0.5=中性、1=强条漫），
  经 `ReaderSessionSettings` 只读投影给分类器，非中性值参与 profile fingerprint；旧单向 weight 按 `0.5 + weight/2` 兼容迁移。
  Venera `comic.adaptiveType` 已由 typed source descriptor 接入 classifier，来源名/官网也由 App composition 投影。
  adaptive profile 现在重新作为跨行为输入：无显式方向时可选择方向；长按放大按漫画显式覆盖 >
  adaptive 类型建议 > 模式默认解析（条漫默认关，页漫/动图默认开）。显式方向不再停止 profile 更新，
  为后续翻译等消费者保留同一结果，同时不改变 Pipeline/NetLane owner。
  来源级应用策略已统一收口到齿轮“源设置”：条漫置信、source-scoped 数据信任、来源独立下载目录；
  旧 plugin-scoped 数据信任只在完整 source 集已由 installed-plugin authority 证明时退役；partial runtime discovery 会保留兼容 fallback。
  configurable source 自身设置/登录改为“来源属性与登录”。每漫画“使用自适应设置”独立于手动设置 master，
  阅读方向只保留跟随/LTR/RTL/纵向；“启用本漫画覆盖”只控制手动覆盖，清除覆盖不再清 adaptive policy/profile。
  全局分页方向为 LTR/RTL/跟随来源，默认 LTR；纵向拼接等只属于单一布局的选项仍保持单 owner。
  阅读设置现由独立 `ReaderModeSettings` 分别保存 paged / continuous：连续阅读、双击倍率/锚点、长按启用/倍率/移动/拖动边界、zoom decode boost 可在两种布局中分别取值；旧扁平偏好会迁移进 mode profiles。
  点击设置也已按当前实际 mode 独立：当前只消费 single tap，3×3 每格可选默认/上一页/下一页/上一章/下一章，单击切页动画可独立关闭。
  Reader 内入口现改为当前页面上的沉浸式覆层：两条横线/两条竖线可直接拖动，归一化 layout 与真实 hit-test 共用同一 authority；
  编辑层 9 个 cell 覆盖完整 viewport 并截获 pointer，底层 ReaderView ancestry 始终保持不变；divider draft 只重建覆层自身，保存后才一次提交当前 mode。
  preference 使用 `gestureActions.singleTap` 分层；PageHost 仍负责单击/双击/长按消歧，双击与长按没有被九宫格接管，为后续各自独立九宫格保留边界。
  Reader 顶部保留强制重载直达按钮；本漫画阅读设置已移到底栏阅读设置图标，右上杂项收纳全局阅读设置、点击设置、来源 WebView 与系统浏览器入口。
  Reader 新增按 mode 独立的“连续阅读”：只控制章节边界 UI traversal，不控制预加载。章节仍一章一个 immutable manifest/session；实际跨章前 flush progress 并通过 HomeLibrarySession 持久确立目标章。
  章节 logical previous/next 现按 sequence 升序定义，不再继承详情/source chapter 的展示顺序。
  continuous 以真实 ScrollPosition 首/尾作为边界 authority，边界后的单指 pointer pull 决定是否提交；
  普通interior current仍按viewport center，但真实min/max extent现分别映射首/末页，短末页不再把progress/current回退到较前页面。
  layout/ballistic ScrollNotification 不再同步写 UI ValueNotifier；沿既有 post-frame observation owner 发布，已消除实机跨章时 `Build scheduled during frame` → `_dependents.isEmpty` 连锁红屏。
  相邻章 preparation 的 null/error 不再永久留在 route coalescing cache，瞬时 Venera/source 失败可在后续 pull 重试。实机 `venera:jm`“唬爛也冇關係”已验证列表 6→1 显示时第5话底部仍进入 logical next 第6话；Trace 为 sequence 4→5 且无 chapter taskFailed。
  2026-09-27 对当前 Reader 用 native-release Profile 重新复核滑动：连续模式 120Hz scroll cadence 大多数窗口均值约 8.4ms、窗口最大约 14.8–15.8ms；
  分页模式 8 次快速横滑 gfxinfo 为 92 frames / 0 janky / p95 6ms / p99 9ms。此前设备最终残留的是 Debug build，
  因此该次“滑动卡顿”不能归因为 scroll physics/Pipeline；性能复核必须继续以 Profile/Release 为准，不以修改阻尼、刷新率或预取水位掩盖。
  加载侧已与 frame cadence 分开归因：fresh JM 静态页观测到 source open 约 261–798ms，分解后 raw open 约 58–481ms、raw collect 44–74ms、
  isolated `modifyImage` 约 158–174ms；UI/render 同轮未出现 gfx jank。promoted exact bytes 在 durable store 期间先以 non-durable hot projection
  供持有该 DownloadSession 的 presentation 使用；最终 Profile 两次 force reload 均在 store 前完成 presentation read，分别提前约 63ms/57ms，
  first-frame 也均早于 store commit。store 失败/新 generation 会撤销 projection，普通 durable lookup/cache-management 仍不会把它误认成持久化完成。
  Venera canonical source WebView 仍严格单 invocation；只有静态/动态资格都通过的 isolated `modifyImage` plane 有界为 2 worker，
  每个 worker 独占 WebView/Bitmap namespace。历史 uncached Profile 中 origin completion 常以约 105–226ms 间隔成簇，与
  100–224ms 的 JM bitmap transform 时长重叠，因此原单 transform gate 存在真实排队窗口；两槽 gate/worker 的并发契约已通过
  runtime adapter 测试。单次非破坏 fresh-reload 实机样本因网络完成错开未形成重叠，故不宣称 2× 实机吞吐。
  2026-09-27 后续 Trace 又定位出 UI navigation 越权影响 demand lifetime：旧 slider scrub 会把稳定 11-download 工作窗压成
  3 个 visible/current demand，再在松手时恢复 11，已加载/预热邻页因此被正常 plan diff 主动 detach。现在
  `Interaction.scrubbing/jumping/settling` 不再拥有独立 resource membership；vertical 所有真实 visible coverage 统一作为
  transition foreground，7/3 window 始终由真实 viewport/current 解析。最终 Profile scrub 47/47 个 policy decision 均保持
  downloads=11，整份 Trace 的 download-count 集合只有 `[11]`、`taskFailed=0`；相邻 scrub 单测固定要求 1-in/1-out。
  在此基础上，ADR 0330继续拆开membership与execution depth：50ms latest-wins只限制viewport提交频率，不再被误当成预取预算。
  scrub时current/transition/真实visible encoded demand保持claim但仅`localOnly`，hidden 3/7 claim为`retained`；decode demand保留identity但hidden target为0，upload demand保留identity但hidden `prepareOutput=false`。
  松手回stable即使window未变也会因resource phase变化重新投影，并在同一physical task上恢复full work；active transport降级只park为NetLane demanded=false/rank0，不cancel/reopen。
  physical alias聚合先按执行资格、再按同层priority选provider/rank，禁止高优先级retained identity把exact provider或rank捐给full work。
  focused Pipeline/DownloadTransferOwner/LiveCoordinator tests现为100/100，覆盖scrub→idle原位恢复、retained/localOnly不打开network、同一task key升降级、同/跨consumer alias，以及localOnly→retained立即撤销旧local preparation。
  2026-09-27 Profile真机slider从112/153快速拖到152/153：31个scrubbing policy decision全部保持11个logical Download claim；执行投影仅出现8–10 retained + 1–3 localOnly、0 full。
  hidden decode target=0为8–10、upload prepare disabled为9–11；松手stable后章尾合法窗口全部恢复full，`taskFailed=0`。该样本无network start，physical park/revive由上述单测验证。
  后续15-26-08真机Trace确认visible并未误判，3个visible页对应3个`localOnly`；真正问题是durable restore只有2个operation slot，旧页降为`retained/priority0`后active restore仍继续占slot。
  首轮4.3s scrub有8个restore以effectivePriority=0退休，active最长71.98ms、total最长113.809ms；artifact-cache整图read多为3–15ms。现已收口为retained即撤销旧local execution，slot仍待Future真实退出。
  修复后15-41-33 Profile复测50个scrubbing decision仍保持11个Download claim且`taskFailed=0`；local preparation不再有effectivePriority=0退休，active最长降至27.40ms。
  后续held-slider复现推翻“剩余只是raster延迟”的归因：pointer保持4s时current=144一直只有visible=[144]，而145/146 PageHost已挂载却直到UP后才拿尺寸/首帧。
  根因是unknown vertical ratio会先占至少一屏，而scrubbing被错误纳入scroll-stable geometry冻结；current短页720x700的新ratio无法缩短extent，相邻页因此永远不能成为visible，transientPreview又正确把它们保持hidden，形成geometry↔execution bootstrap死锁。
  修复后Profile held-slider在UP前完成`scrub-visible-ratio`提交：target100由visible=[100]扩为[99,100,101]，同一transientPreview内localOnly 1→3、hidden retained 10→8；页101/99首帧约95/128ms完成，UP约4.9s后才发生。11-download membership与hidden gate均未扩大。
  2026-09-28 对最近Reader修复做生命周期反审计后，4项P2均被新回归先证伪再修复：
  旧vertical command Future不再写idle覆盖真实drag；physical claim移除与新增/更新共用aggregate execution projection，
  retained survivor不再让旧local restore占slot；点击区域save绑定edit-session token，旧保存不能关闭reopen后的新overlay；
  短页章节真实max extent直接映射最终页。同步做了三项纯减法：scrub ratio去重遍历、decode first-frame候选改为单遍best selection、
  两处点击动作label/icon共用helper。full gate 随后暴露 dev.114/dev.117 对 refill 具体源码字符串的误报，已改为稳定 stage + executable behavior regression 合同；
  Reader Kotlin compile stub 已补齐当前系统栏使用的 Android API，Android 平台 guard 保留。
  2026-09-28继续对照Mihon后确认剩余represent偏移不是“decoder并发不足”：Mihon WebGPU decode本身单线程，
  但continuous viewer把真实viewport/adjacent页放在同一page-cache生命周期；旧Webtoon holder进入实际绑定后也会从adjacent preload提升为正常page load。
  ZIC随后修正三个边界：transition first-frame从单槽改为可重复viewport role；vertical `viewportVisible` output prewarm不再等待idle；
  scrub现允许既有`next/next2/previous` static deadline以local-only一帧进入统一presentation raster cache，
  external-static decode handed-off后也不再等待presentation ack才释放下一staged refill。
  outer `near/far`仍retained/target0/prepareOutput=false，50ms latest-wins和remote gate不变。
  Profile同机样本的`adjacent firstFrameReady-current`从修复前n75 median/p90/max=16.1/48.7/82.1ms、80%偏慢，
  降到最新n32的0.0/29.9/32.2ms、53.1%偏慢；Trace出现大量detached `preparedOnly=true`后viewport `prepared=true`直接复用，且`taskFailed=0`。
  因此主要current偏置已关闭，剩余尾部约两帧暂不通过扩大speculative并发处理。
  2026-09-28继续复现出release geometry漂移：backward slider held 47%时current=82/logical=82.5，pointer-up后约38ms变为current83/48%；
  同时scrollPixels约75549.63→74784.19。根因是held scrub按selected center提交ratio，而pointer-up后的pending prefix ratio改用idle top-anchor。
  slider-selected index在放手后的晚到尺寸更新中仍保持center anchor，直到真实content motion或新命令退休；已知prefix ratio在held阶段即提交，新暴露visible的pending ratio在后续layout消费（ADR0354）。
  同轮确认previous慢不是“只有两个worker”：旧transient static次序为current1000/next820/next2 800/previous780，即使3 slot仍会让previous最后。
  scrub现把immediate next/previous统一为820，next2保留800；Profile可见相邻首帧prev n18 median/p90/max=48.8/82.3/98.3ms，
  next n17=47.4/76.7/80.5ms，两次held均在UP前完成相邻firstFrameReady且`taskFailed=0`。worker与7/3/NetLane边界未改。
  同一轮后续手动Trace又暴露两项独立presentation/navigation生命周期问题：末次held scrub在current=98时physical viewport未动，旧实现却因scrub phase用整数logical、UP后恢复center fraction而产生logical 98.0→98.5及约+3.50 pages/s伪速度；
  35个tap区间另有131次presentation sourceRead，其中28次为同页重复读取（21.4%，累计约188.7ms），detached raster已经prepared后mounted consumer仍先重开encoded presentation file。
  现selected page只覆盖navigation identity；held scrub中的physical logicalPosition会随实际layout revision在pointer-up前重新发布，absolute scrub自身velocity固定为0且不更新travel direction。
  mounted external-static先按同一presentation identity直接attach统一raster owner已有completer，owner miss才回退encoded acquisition。
  同一新Profile Trace的artifact-cache presentation-file-lease为26次/26个unique identity、重复读取0；同任务pre-fix 11-18-08为64次/37个unique、27次额外重复读取，重复identity累计readMicros约531.5ms。说明resident-raster mounted attach已切断“prepared后再重开encoded file”的重复路径。
  Reader/media 当前验收统一更新`docs/IMPLEMENTATION_STATE.json`，既有RMR记录已归档。RMR-011..017七项由production source独立确认的已验边界保持。
  presentation侧包括：same-generation first-frame仍按widget lifetime去重；managed raster decode error被同步eviction先撤下error/authority；requested→ready分步通知制造瞬时双false；widget级recovery gate会吞新grant；旧rendered error可污染新attempt。
  worker侧包括：每请求向长期exit Future挂continuation；dead worker退出后仍留在可调度集合。
  当前external presentation改为一次完整`requested/ready` state commit，并以不可变`_PresentationAttempt(loadEpoch, token, opaque identity, exact read authority)`统一first-frame/error/recovery/final publish。
  same-generation regrant取得新的local attempt但不旋转presentation identity；managed raster decode failure先保留当前error channel而不是伪装成ordinary residency eviction。WebP metadata prefix旧async drain无await，已删除syncing/双revision/递归外壳，只保留同步prefix读取与单调length去重（ADR0337）。
  native decode/source-write worker现在各只安装一次exit listener；worker持有至多一个current active-response completer，真实exit结算当前请求后由pool退休dead worker并有界补位。
  request只持短命response subscription，不再向process-lifetime exit Future持续注册then；真实capacity由active-run unwind结算，decode退化为单live worker时non-current让出最后slot（ADR0338）。
  RMR-032已将延期global耦合改为App显式绑定`PipelineStaticPresentation`：同实例供Pipeline authority/prewarm和mounted UI；local独立raster仅消费纯resize，未新增owner。custom authority失败先行集成回归、local_media_ui34/34与全仓2136项及Rust22/22通过；
  ADR0351..0353 Accepted：native Profile slider/跨章/重入通过；JM180项/8页、Pixiv五语言/全来源144项0失败。一次JM init HTTP命中10s，30组manifest恢复通过；synthetic requestId诊断盲点已补，第二台8轮冷激活0.98–1.19s、headers699–922ms/body0–4ms，旧长尾子阶段仍未归因。
  真实MangaFire筛选UI已完成：Safe/OR/Action三项跨重建保留、应用、重开、恢复默认与返回热门均通过；unknown Filter边界由实际Kotlin codec执行验证。
  第二台API36新02-18-27 Trace有1376事件，真实31→38→31、taskFailed0；14次current边界reconcile中位618µs/max955µs、uploadStarted0。同次内容层667个手势内部gap p99=8.319ms/max8.320ms；FrameTimeline缺ZIC内容层、视觉暂不可用，性能仍partial。
  本次buffer与service lifetime丢弃计数已分开；副标题opaque locator与关于旧版本已修并实机验证。包含这些修改的2138项+Rust22全门禁通过。
  ADR0354已Accepted：2140项/Rust22全门禁通过；实机冷页116/21放手后尺寸晚到约808/951ms，首帧自行到达且页码稳定，真实drag正常退休anchor；四次跨章方向/首尾落点正确。新确认冷章节source激活竞态、idle重入伪velocity已最小修复，2148项完整门禁与第二台fresh trace通过：冷入口等待source成功、37条idle速度零且真实drag保留速度（ADR0355/0356 Accepted）。
  Profile00-52-07 authoritative Home1.287s、external request/first-frame=33/33、mounted无后续first-frame=0；sourceRead33次/22 identities且5s内重复0，taskFailed/force-reload/artifact-recovery均0。
  decode pending queue的request-level control已独立治理：`DecodeLane CancelToken`经`DecodeSession -> ScheduledFrameCursor -> NativeCursor`原样进入native pool。
  queued cancellation可直接移除pending，动态numeric priority由同一control驱动class内排序，current/nonCurrent仍只表达execution class；role promotion先迁移DecodeLane rank再迁移同一request class。
  in-flight取消不提前释放worker capacity，source/decode retirement等待lane真实退出（ADR0339）。focused DecodeSession/LiveCoordinator回归与native decode ownership guard已通过。
  Reader/media40保持36 resolved/2 deleted/2 confirmed，下载原13闭合；原112范围保持，Plan074转partial。0385 Accepted：真实E-Hentai新版发现/551页详情/比较预览与三静置slider/四首尾通过，bootstrap/56项、2221/Rust22及三ABI通过；0383首次入架/后续版本提醒、原加载与最终显示仍开放。
  progress旧“pop不等durable”文案已按Accepted ADR0303校正；普通翻页仍8s idle/30s active批量，正常pop先final drain/flush，返回仅targeted投影。旧文档guard同步当前合同，产品/性能长会话验收继续。
  下载治理：下载审计JSON的13项均已闭合。DL-PIPE-001保持共享consumer/NetLane的2-wide滑动窗口；ADR0343保持唯一index，current backup须CRC匹配才恢复，stale intent全CRC，live commit不重扫。SAF真机9组kill/reopen+1组幂等及required-toolchain gate通过；downloads504/504、App383+3既有skip、Rust22/22。
  partial复用继续收口到physical authority：03-03-51 Trace中page79/exact `6d924728a464c2c6`已有7,708,375-byte canonical SAF partial，却因不可borrow而经DownloadSession writer从0本地重放并被投影成receiving；同identity当段无origin sourceRead。
  现在persistent store在per-physical serializer内先将SAF authority安全迁到App-private Direct transfer staging，再borrow给hot session，generic fallback不变（ADR0340）。
  current-source Profile `zic-debug-trace-2026-09-29T03-35-53.jsonl`直接命中同一7,708,375-byte SAF partial：`accessMode=saf/adoptable=true -> adopted-physical`，local hydration结束仍为idle且未发生本地`receiving from 0`；随后03-54-39同页直接`adopted-posix-spool`。
  provider之后对`Range: bytes=7642839-`返回HTTP 200而触发full-body-prefix-catchup属于独立Range rejection；partial仍被保留，不与authority-loss混写。
  ADR0340后续反审计确认首次SAF→Direct接管仍有冗余I/O：旧prefix曾被pre-copy CRC、copy、同步cleanup CRC各完整读取一次。当前实现删除pre-copy扫描，在实际copy中累计cleanup CRC；新Direct authority提交后只登记durable cleanup debt并异步drain。
  hot takeover/取消不等第三遍SAF扫描；7MiB+回归证明返回时仅读1遍，delete-time proof为后台第2遍，后续Direct adoption不再读SAF。worker补位失败仍有live worker时保留pending、degraded执行，单decode worker保留current-only最后slot；live=0且补位失败才终止pending。
  decode numeric priority在selection时读取同一TaskControl，不镜像pending或订阅`priorityChanges`；queued cancellation与显式current promotion不变（ADR0338/0339）。
  RMR-022/023已闭合：opaque grant内部绑定DecodeId、UI只见cache/state/ack；唯一PipelinePresentationRasterCache未变，mounted/detached共用owner adapter。focused 33/33+16/16、dev.77/80/114及最终`--require-toolchains` 172.55s均通过，无新增Reader owner。
  release-native Profile06-32-20 authoritative Home1.283s、Reader first-frame、taskFailed0及multi-MiB Direct adopted-physical通过；该轮无可复现SAF partial，SAF读取次数/取消边界仅以fake-SAF回归验收。
  RMR-031闭合基线：Reader73/73、Home11/11、DownloadSession90/90、retention35/35、Kotlin与required-toolchain gate、三ABI debug/Profile、Rust22/22通过；RMR-032全仓/设备复验已通过；扩展Plan验收仍进行中。
  TTL4/LRU、used texture、active decode/prepare退出保持。pending present退出/重入与prepare原Future期间重入1/12已验，另11时窗未覆盖。新demand可持旧活跃cursor，最后退出才退休；631事件/0失败/0重读。实际CPU blit/GPU、真实代际开放。125完整payload/67read保持；19话APK/1.6.22provenance保持。
  之后fresh Profile继续把“逻辑next比current晚”定位到local preparation的operation-cap tie：三页真实visible时current1000与两侧transition900已经同级，
  但严格max2会让第二个900按stable claim顺序多等约3.7–15.4ms。ADR 0334不全局扩容，而只给同Reader/revision、三者均`localOnly + viewportVisible`的cohort一个第三operation handoff；
  `DownloadDemand.viewportVisible`现直接来自Reader observation而非role推断。修复前13-26-45 matched fast-forward样本`next-current`中位约+18.21ms；
  修复后14-15-30长双向Profile中forward n=19与reverse n=11均约+0.01ms。48次production handoff queue wait median/p95/max=158/747/1654us，`activePreparations`从未>3。
  将visibility进一步收口成`ReaderObs -> DownloadDemand -> TransferDemand`显式fact后，最终源码重新构建Profile并得到14-33-10 Trace：forward n=17、reverse n=10的`next-current`中位仍均约+0.01ms；37次handoff queue wait median/max=166/1684us，active从未>3且`taskFailed=0`。
  已热previous仍可早于current/next，这是resident raster复用而非待消除偏置；少量Flutter raster/host长尾继续作为独立presentation问题，不用扩大NetLane、decode/upload、7/3或2/1掩盖。
  相邻章预加载已下沉到 composition transfer owner：只补当前章前 7 / 后 3 encoded window 的残余水位，不额外扩大窗口；同一 preload lease 随当前页伸缩 demand。
  priority 500 opportunistic claim 共用既有 DownloadTransferOwner/NetLane/ArtifactCache/partial state，并继续受全局 50MB speculative encoded-read budget；UI 连续阅读关闭时预加载仍存在。
  系统状态栏为 `显示 / 隐藏 / 跟随控制栏` 三态，默认显示；follow 模式复用同一 Reader controls visibility fact。Android 16 / targetSdk 36 使用 reader_runtime 原生 WindowInsetsController owner；Reader 退出恢复系统栏。
- 页面几何：ValueListenable 提供 pageDimensions 驱动的 ratio live feed 投影。
- 纵向模式：vertical模式只有extent真实变化 才能触发 ListView-local anchor/geometry rebuild；pending-only ratio live feed 不再 dirty 整个 ReaderView，vertical模式 保持布局稳定。
- 纵向drag输入：ADR 0325以healthy ~8.3ms frame下的逐帧位移而非cadence gap重新归因。
  无resampling的匀速drag相邻速度变化均值约9.9%–18.3%、单窗13–15次>20%、max 255%；Flutter built-in resampling对照降为0次>20%、max<=0.0171%。
  `reader_runtime`因此恢复vertical生命周期ref-counted lease，最终release恢复进入前全局值；ballistic cadence结论不变，`samplingOffset`/自定义插值/forced frame/ScrollPhysics仍冻结。真机最终验收还需确认视觉改善与直接操控延迟均可接受。
- 视口与上传：vertical active期间native static只继续defer `far/near` speculative upload；既有2/1 deadline窗口的`next/next2/previous`一帧允许提前UploadLane/present并retain。
  vertical real UploadDemand会在host mount前预绑定detached output consumer，避免ready output形成秒级`outputReadyToPresent`等待。source-canvas 与 decoded raster 职责仍严格分离；
  64B metadata ABI保持，JPEG另以最多64KiB的一次性dimension probe提前解析SOF用于纵排extent。
- external-static presentation：统一 `PipelinePresentationRasterCache` 同时拥有 managed raster 的 residency、LRU 与 speculative re-admission backpressure；
  mounted Reader static 绕过 Flutter `Image`/`ScrollAwareImageProvider`，只持当前 `ImageInfo`，撤销 presentation permission 时同步释放。
  `_externalPresentationEvictedWhileFar` 已删除，budget eviction 不再由 Pipeline 镜像 tombstone；deadline/protected claim promotion 直接解除 cache-owner backpressure。
- 原生纹理呈现：以 presentationIdentity 标识 resident surface，接入 Android SurfaceProducer。
- 后台执行收口：ADR 0328 改为按实际阻塞成本分类，而不是统一“放后台”。version-candidate `Isolate.run`、prepared-demand two-phase commit 与额外 source-wake deferred queue 已撤销，保持同步 owner-local control；Reader observation 只保留同 isolate 的 frame/event-turn 让行。
  真正毫秒级的 resident source reserve/copy/file-range 继续由 native source-write worker 执行，既有 priority/cancellation 贯穿 pending queue；decode/source-write worker lifecycle 显式拆分。
  artifact object/replica/root 约0.13ms的 metadata 读取已撤销常驻 read worker，直接在 SqliteIndex owner connection 使用短单事务 snapshot；recency touch 的同步写成本约2ms，仍先经过既有 StorageWriteScheduler admission 后交给 worker。
- 缓存与淘汰：promoted LRU=8 维护热尾淘汰，当前 current 拥有最高抢占权威。
## 2. 当前开放问题
- RMR-037：ADR0364–0377已验分量保持；8162事件验明静置slider与首尾跨章。48.162ms属拖动→惯性交接，37.640/43.308ms有匹配CPU；旧返回35.255/20.331ms及新21章入口34.772ms无匹配栈。Profile返回GC15.557ms、输入延迟/最终显示仍开放，见cadence/home-alias/source-card审计。
- RMR-038：ADR0367/0368 Accepted；2184/Rust22及三ABI/JNI通过，冷启动/刷新/Reader后28行/1184页及首尾复验。展示不改变预览/正文裁决，memo缺失历史保留；备份保存/取消/重试与共用Trace通过，全来源metadata开放。
- 静态竖排功耗报告已于 2026-09-24 重新按当前 owner 链复核：idle 恢复 3/7 static warm 是既定资源平滑策略，不作为功耗缺陷移除。
  Plan 会同时声明 one-frame intents，但真正 decode 仍由 `StagedDecodeRefillPolicy` 每次选一个 refill；Reader profile 的 bounded lanes 不等于整窗同时执行。
- ratio“逐页整树颠簸”报告部分过时：`reader_runtime` 已按 Flutter frame 合并 source-canvas ratio 发布，decoded raster 不能覆盖已知 source-canvas geometry。
  未取得 fresh trace 证明仍有跨多 frame 的 source-canvas storm 前，不再增加 debounce/Reader-local 几何旁路。
- 初始 6-screen `cacheExtent` 到首个 ScrollEnd、nominal `current±7` KeepAlive 与每 frame 最多 3 页的 idle recenter 均保留为 composition 策略；
  它们不扩大 Pipeline 资源窗口，offscreen subtree 由 `TickerMode` 静音，暂不按泄漏/功耗 bug 处理。
- 已确认并修复的额外成本：Dart `verticalSceneMotion` RenderBox/global-matrix probe 与 platform cadence probe 共用 `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS` opt-in；普通构建不运行该纯诊断逐帧采样。fresh功耗复核开放。
## 3. 验证矩阵
| 检查项 | 状态 | 说明 |
|---|---|---|
| repository / documentation / Dart 静态门禁 | Verified-static | 当前文档/所有权门禁重跑；.log仅6必要原件，完成trace/helper及时删除，私有缓存同规则；当前XML/日志按用途覆盖。共享临时目录仅删本任务明确路径，Runner退出码须结合实际结果 |
| 架构合同与生命周期 | Verified-static | Reader/Pipeline/Sessions 边界已验证 |
| 自适应阅读来源先验 | Verified-device | model v8 一次性 3 页以内几何判定、异常切片中性区、双向条漫置信迁移/持久化/UI、Venera adaptiveType runtime 投影及方向/长按分流均有 focused contract；肉漫屋《要成為男子漢》真机复核为 vertical / 70.83% / samples=3 / modelVersion=8，继续停留后 samples 仍为3 |
| Reader 设置与系统栏 | Verified-device | Android 16 / targetSdk 36 真机验证 status bar 显示/隐藏、控制栏独立导航栏行为、Reader exit 恢复；漫画级 adaptive 与手动覆盖入口也做了真机 UI 验证 |
| 跨平台桥接与平台编译 | Verified-toolchain / Unverified | required2342/Rust22/27suite/analyzer、三ABI Debug/JNI已通过；六普通Profile/Release与native112复用同输入，3既有quarantine跳过。Release ce59d78d/PID3018/Home；连续手势/延迟/最终显示开放 |
| 设备性能与真机回归 | Verified-device / Unverified | 几何/TTL/LRU/native退出重入保持；19/20缓存静置/独立历史及21话真实slider下载已验。050：20/21各存5/75页且重入恢复；另Venera17到2页后首返Home移首位。125payload/67read既有保全结果保持；原19/20偶发加载、active视觉、GC/输入/最终显示开放 |
| 未集成组件与缺省归档 | Unverified | 部分外部归档与端到端链路未覆盖 |
  当前112项：device45/toolchain10/superseded2/partial33/pending22，55条未完成记录。012四故障分支、029原schema/default、053/092诊断边界已收口；019/085–087拖动及008/101冷partial保持。009饱和lease、wire013/DNS089及性能独立开放；通过场景停止。
