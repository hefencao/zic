- P0：RMR-037继续输入交接/延迟、GC/入口CPU及最终显示验收；先以普通手动操作和当前原生接收对照定位Home输入，未证实命中前不做Reader性能结论。融合locator候选已撤回，不凭API推测收益或跳过兼容。原加载/固定顿挫、RMR-038与Plan039/040真实来源开放，保留NetLane、7/3和2/1。
- P0（dev.325）：补固定位置顿挫与current role promotion的真机视觉/最终呈现关联。保留已满足static decode与ready retained static upload的owner-local no-op合同，使用`analyze_current_role_boundary_jank.py`分离边界reconcile、`uploadStarted`与最终composition。current中心判定、startup artifact-pressure、7/3、decode2/1、current±2、bridge及dev.323 present fast path保持；只有fresh失败证据才重开已验控制面分量。
- P0（dev.324）：05:33 dev.323真机已把direction-flip附近resident static重复present从dev.322的52次降为0，但用户仍在同一固定位置顿挫；因此停止扩大presentation continuity/keepAlive或继续调bridge。现有App内证据已到边界：Choreographer/Flutter/scene motion大体120Hz且scene residual为0，Window FrameMetrics未覆盖active-scroll异常。dev.324只做observation：同一设备/位置同时抓SurfaceFlinger FrameTimeline与active layer composition/buffer/HWC证据，离线按ZIC layer统计actual-present gap、late/jank/fence/GPU composition。命中content-layer或SF jank才继续下钻buffer acquire/latch/present；FrameTimeline仍连续则转layer transform/content transaction，不再修改Reader/Pipeline行为。
- P0：补dev.282首次新OutputFrame的native呈现成本与快滑最终composition验收。保留lease零copy `platformResidentReuse=true`和exact retained static重新claim/project fast path；role重入不要求恢复旧重复present timing。首次frame独立测blit/schedule/frame timing，余下顿挫只按fresh证据定位首次visible/current frame与SurfaceProducer/compositor，不重改已验geometry/anchor或窗口。
- P0：按dev.280 scroll-stable geometry的现行合同补真机视觉验收：保留painted extent；允许视口之外forward ratio预备、reverse prefix原子anchor校正及slider真实visible ratio采用。物理观察只用已布局geometry，剩余ratio在idle latest-wins提交。已验组件见ADR0330/0361与loading审计；不得恢复active全冻结或逐ratio jumpTo。
- P0：真机验证dev.273 durable partial read owner解耦：普通无local state页应记录`local-hydration-miss`且prepare成本显著低于dev.272约87ms中位；exact+verified-equivalent miss不得materialize durable-store `DownloadSession`。真实cold partial命中仍应`local-hydration-ready`且`committedLength>0`，并在provider `downloadStarted`前发布可消费prefix；local bytes继续只由`ArtifactCacheReadScheduler`调度。若真实hit后仍无首帧，冻结下载层并转查Decode→Upload→presentation generation。
- P0：真机验证transport/source lease与body-read permit已解耦：normal steady state `globalTransportLeases<=5`、current handoff最多6；parked live response不得释放transport lease，durable artifact local body必须释放两者。比较`sourceRequestPlanMicros/sourcePlanGateWaitMicros/sourceHostOpenMicros`相对dev.270是否回落；若仍慢，分别下钻Venera单invocation gate与host open，不扩大连接数或缩3/7。
- P0：真机验证 current body-read 抢占与 inactive response retention 淘汰已解耦：`downloadPreempted`只允许表示priority/body-read preemption，后台 retention destruction只记录`downloadEvicted`；一个正在退出的inactive response不得阻塞current live response reacquire。继续验证`demanded=true` flow-paused response不成为retention victim、artifact-cache durable body释放remote NetLane permit，并独立统计重复persistent artifact session-copy，不用提高session/response缓存数量掩盖。
## P0：Image Transfer ownership 正式迁移
- 后续真机验证chapter B与Reader A共享physical transfer时`stored-required-exact-alias`出现、B exact durable可读而A不会仅因B命令新增副本；继续观察`rejected-ambiguous-existing-owners`与proof晚恢复，不恢复hard alias或late takeover。
## P0：Partial authority 单调性真机闭环
- dev.195 的playable partial单调性继续冻结：Range probe/full-body catch-up的取消、EOF或mismatch只能失败当前 network attempt，旧partial/Ingress不变；metadata损坏只丢网络知识。dev.196不改DownloadSession authority、DecodeSession、NetLane、network=5、1000/780、7/3、2/1、7/5/3/2，也不增加bandwidth scheduler/framing。
## P0：Current / Previous 真实执行槽真机闭环
- dev.192 真机首要比较`sourceRhttpProgressMaxGapMicros/sourceRhttpProgressLeadBytesMax`与`sourceRhttpBodyMaxGapMicros/maxChunkGapMicros`：若receive-progress与raw body同时长gap，优先归因源/CDN/HTTP链路；若progress持续前进但body长期滞后且lead显著扩大，再调查rhttp FFI/Dart Stream delivery/backpressure。不得用该diagnostics直接驱动scheduler。
- P0：补dev.276普通来源的resolver warm3 hit+1 page-specific origin与Reader gate/host-open时序；current提升、旧current降级及physical invocation退出的六项设备合同已验。single Venera permit仍须等待JS finished与已接纳native call真实退出，不扩大JS并发或预解析整章。
- 补dev.186真实Reader previous660→780到`downloadStarted`的时序；selected runtime previous pressure已验。780沿原gate请求低40分active invocation取消，JS finished与已接纳native call均退出后才可交出permit，`maxActive`保持1。
- 使用plan/cache/host-open字段继续确认连接阶段；持续传输阶段新增`sourceHostHttpVersion/sourceHostRemoteIpHash/sourceRhttpProgress*/sourceRhttpBody*`与现有`sourceRead` bytes/chunks/gap。只有设备证据同时证明并发active streams损害current且底层pause能真实形成网络backpressure，才考虑NetLane-owned transfer pressure；不得建立Reader bandwidth scheduler。
- 同时复测短时N→N+1→N与跨session跳页：already-admitted task离开demand只降rank0，normal neighbor不得主动cancel；new current先借reserved槽。reserved也满时先保持pending，只有candidate稳定100ms且没有已有preemption in-flight才允许统一rank选择一个victim；若仍出现波浪重置，必须由单次`downloadPreempted`、consumer-bound dispose或真实failure明确归因，不得恢复normal pressure floor或victim-side demotion特判。
## P0：Current 首帧 policy/execution 真机闭环

- 首先验证 current bootstrap：动态 current 未达到3帧前，speculative next/next2/previous 不应产生实际 decode refill；current 等 source 时只允许真实 viewport transition 先取1帧。trace 应显示 staticWarm 不再把 near/far 7/3 encoded页扩成 decode/upload。
- network/decode/upload normal concurrency 继续为5/3/2，三条 lane 各有1个 current-only reserved handoff；transition=900 不占该槽。快速切页时 current 不得等待低优先级高分辨率 decode/upload自然完成。
- Venera current pressure经requestId取消现有isolated Dart rhttp请求；JS finished与已接纳native call退出齐备后才转交single-context permit。selected gate/held HTTP取消已验，真实来源长尾和default system-DNS退出另验；不得恢复旧native HTTP owner、改chunk或缩7/3。

## P0：迁移 / 同源版本 / 更新提示真机闭环

- 用真实存在章节 `sourceUpdateAt` 或 projected confirmed successor relation 的书架 source card，确认右上显示独立感叹号。点击同源更新提示应直接打开来源确认的最新 successor，不得把 successor 自动加入书架。
- 真机从普通入口完成真实同源版本迁移，以及跨源搜索同名候选/手填原生 ID 迁移。确认必须经过同一个比较页面，sequence-only 不复制状态；覆盖实际来源下 artifact/metadata/cleanup callback内部的中断，验证 library schema 11 `source_migration_journal` 幂等恢复。
  `metadataCommitted` 后无需目标源在线，只继续旧 source cleanup；journal phase不得触发Home projection revision。真实来源/普通入口证据须与隔离事务phase-boundary及callback内部中断证据分别登记。
- 真机验证 E-Hentai/Venera 迁移后的 raw locator、canonical identity、SavedComic/偏好别名：迁移到 successor 后旧 raw alias不得继续显示书架标志，状态及 artifact 提交保持对应版本身份。

## P0：Source Browse 封面 owner 与筛选入口真机闭环

- 对同一漫画执行“漫画源列表首帧 → 打开详情 → 返回列表 → catalog后台 refresh/普通分页更新”，确认 canonical cover URI未变化时不产生新的 `cover-load-start`，也不出现 presentation decode重启；只有显式来源 artwork刷新或该卡片自身 URI/identity变化可以换 source。
- 记录 `source-cover:<sourceId>\0<canonicalComicId>` 的 `cover-load-start/source-ready/first-frame/decode-failed` trace，确认 browse projection `changed=true` 与详情 metadata更新不会成为 artwork revision。
- Mihon/source筛选以真实 `getFilterList()` 为唯一 schema owner：非空时分类栏按“最新 → 热门 → 筛选”显示，空列表不发明入口；bridge完整支持官方 8 类 Filter及插件自定义子类，筛选面板以类型化 `filterState`回传 Text/Sort等状态。首次默认 section仍由当前展示排序第一项决定，catalog cache不得恢复导航默认值。

## P0：Artwork 生命周期与更新语义真机闭环

- 使用原始报障 trace 中曾“durableCacheFile → FirstFrame → 数分钟后 DecodeFailed”的同一批封面复测；在首页/Reader往返、内存压力和 response cache trim后，既有 ImageProvider必须继续显示，不得因为 cache-owned `.bin` 被删除而悬空。不得恢复 presentation retry/evict/watchdog。
- 普通主入口用来源实际确认的同源successor验证Home版本更新筛选；以home-update-shelf-admission审计中的当前筛选/metadata/progress合同为基线，不因父项partial改写已验行为。
- 普通主入口验证真实来源版本首次入架确认既有chapter/version通知、后续successor仍可提醒；隔离来源验收不得代替真实版本发现流程（ADR0383 Provisional）。

## P0：WNACG HTTP 媒体与终止失败真机闭环

- 用 `mihon:6551136894818591762` 重新打开 WNACG 列表、详情和 Reader，确认 `http://img*.wnimg*.ru/...` 封面与正文由原 source request成功返回；不得新增域名白名单、URL改写或第二 transport。

## P0：网络 UA / client / cache ownership 真机闭环
- 真机/fixture 同时覆盖完整字节 fallback 与 streaming range path，确认二者使用同一 source-resolved request plan；不得出现 full-byte 直接调用 raw source transport或 metadata/artwork 走 page-body bypass。

- 在设置中切换自定义 User-Agent后分别验证通用 HTTP、普通 source WebView、Reader fallback与插件仓库请求；确认 source显式 UA和 Mihon browser-session UA仍优先，不被全局值覆盖。
- 对 Mihon/Venera source记录 host replay / source-owned fallback原因；redirect、`Set-Cookie`、未知 client wrapper必须在Pipeline前切回source client，正常无状态媒体保持host streaming。非媒体正文按当前typed semantic recovery有界处理，不因protocol mismatch强制runtime重放。
- 全仓 trace核对 metadata/artwork只经 `ResourceCacheManager`；Reader page body只经 `pageResponseLoaderFor`进入 DownloadSession/artifact，不得出现新的 presentation裸 transport。
- 继续验其它transport/partial动画、真实origin/其它Mihon客户端与teardown；真实WNACG1.6受控GET/redirect的正文、原生呈现、冷READY和取消边界见source-mihon-client-pipeline审计。完整输入/canonical整块物化、live stream/backpressure及分配另验，保持原body/cache/NetLane/retry owner。


## P0：Home projection、Artwork namespace 与 Runtime generation 真机闭环

- 同一外部漫画执行 browse → details → history，记录 canonical comic identity与 cache origin；browse已写入的 `artwork-v2` durable cover必须被 details/history直接命中，不得出现 `artwork-v2:artwork-v2` 第二 namespace。
- 冷启动直接激活 `venera:ehentai`：若首次 Binder generation在 activation完成前 died/disconnected，Android runtime-service client最多保留原 pending activation跨一个新 generation；若新 generation仍死亡，导出 runtime process crash/LMK，不增加第三次重放或 Dart/plugin层 retry。
- 继续对 `home-history:<canonical identity>` 对齐 source/cache/decode trace。source可用但持续 `Failure` 时沿 request/transport本身调查，不再由 progress rebuild、source-ready retry或 cache namespace分裂掩盖。

## P0：Mihon目录、Venera生命周期与图片网络设备闭环

- Roumanwu：复取历史exact 80章真机样本，核对raw SManga与升级/旧durable manifest刷新路径；不得用当前42章样本或JVM80对象合同替代原样本验收，见source-contract-acceptance审计。
- 禁漫天堂：升级后确认durable details/chapter cache revision触发真实刷新；历史单个完整 `SChapter` 分支仍需保留原对象并采集trace，不以当前350章或无durable cache的fresh探针替代。Cloudflare不调整。
- 绅士漫画：先取得保留自定义响应/镜像/压缩语义的请求级证明，再验证cover/page直连与 `sourceMediaProtocolMismatch` fallback；不得扩大标准client白名单或改设置使验收通过。
- Venera：连续修改镜像/设置和完成 Web登录，确认 active source/session不被 replacement；安装超过8个混合外部插件，确认生产32-session上限下不会因第9个开始静默消失。

## P0：详情Artwork API与重复解码设备闭环

- 真机打开含大量预览/评论头像的详情页，确认普通 artwork每项只有一个 provider listener；裁剪/尺寸测量项只有一个显式 ImageStream listener，build/layout与 decode不因加载占位再挂第二个 Image。
- 对 cover/preview/avatar分别导出 gateway role/cache key，确认详情 loader显式透传 role且不会全部误写入 cover namespace。

## P0：Reader热路径、Mihon章节与Artwork身份设备闭环

- 用同一 Mihon漫画在 browse、details、history记录 raw comicId、canonicalComicId和 cover locator；即使 SManga标题/简介/thumbnail/memo变化，三处必须命中同一 canonical artwork namespace。
- 在source暂不可用时补真机`mihon:resource:` durable封面命中和durable miss等待来源，不能回退local file loader。

## P0：Cloudflare会话、详情路由与插件恢复设备闭环

- 在发生“验证接近完成又重新开始”的设备上确认验证 WebView使用 provider真实 UA；导出 handoff snapshot UA与 Mihon首个重试请求 UA，必须一致。若 challenge仍循环，继续检查 TLS/IP/站点策略，不得重新伪造 UA。
- 在插件runtime激活失败时重启App，验证durable封面命中和miss等待来源恢复。

## P0：Mihon 插件识别设备闭环

- 绅士漫画：补非空Cookie/POST的真实request-plan覆盖，并验证保留自定义client语义的host直连可读正文；现有GET/Referer/UA/null-body和runtime解码不能替代这些条件。
- 已激活插件连续执行 WebView验证、设置修改和同包更新；故意让 replacement activation失败，旧插件必须继续出现在 activeSources并可请求。
- 使用直接字符串和 `@string/...` metadata 的真实 Mihon APK分别验证 extensionLib、单入口和多入口 class解析。
- 记录真实插件重启后Cookie snapshot reset与首个request时序，确认reset先发生；五个插件restart后可读与static common-runtime预检不替代该设备条件。
- 对无法识别的 APK导出 package、metadata key、ABI和 entry class诊断，不能静默表现为“未检测到”。

## P0：身份、同源更新与验证设备闭环

- 使用真实 Venera/E-Hentai successor 检查详情“有新版本”、统一比较确认和 Reader 首次提醒；确认换 successor 后再次提醒。
- 在普通入口使用真实同源版本复验章节对应关系：title+sequence exact confidence仍须校验目标原生身份；sequence-only 候选不复制阅读状态或 artifact。
- 在禁漫天堂真机验证两条分支：真实 `challenge-error-*` challenge进入 WebView并完成 handoff；仅含 Cloudflare challenge脚本/普通403的响应不产生 `sourceVerificationRequired`。确认 WebView不会在 Cloudflare尚未完成时因一次 `onPageFinished` 提前返回；Turnstile/JS challenge存在期间持续停留，最终页面连续稳定无 challenge后才自动保存完整 Cookie/UA snapshot并返回，且不要求生成新 `cf_clearance`。
- 使用真实 Mihon 1.4/1.6扩展验证宿主调用顺序：1.6先 `getMangaUpdate(...fetchChapters=true)` / `getPageList(SChapter)`，1.4仅能力缺失时回退 legacy。用禁漫天堂确认 source返回的每个完整 SChapter原样保留且不按相同 URL折叠；Roumanwu原80章不得再因错误入口刷新成0章。

## P0：来源投影、Cloudflare 与封面身份设备闭环

- 在 Venera/Mihon 多次切换且目标请求失败时，确认页面在同一帧切换为目标缓存或目标 loading/error，绝不显示旧 source 卡片。
- 对禁漫天堂执行强制刷新，确认只有真实 Cloudflare challenge 产生 `sourceVerificationRequired`；普通 403/timeout/解析错误保持原分类，主/兼容 interceptor 行为一致。
- 完成一次手动或自动验证后故意保持 runtime失败，再连续点击刷新/重试，确认不会再次自动跳 WebView；手动“网页验证”仍可重复打开。
- 验证打开浏览器后立即取消/Activity中断不会擦除此前同站点/同 UA有效 snapshot；确认 snapshot revision仅在成功 capture时前进。
- 让同一漫画同时进入更新、书架和历史，并改变 raw Mihon alias、resume chapter、Home enrichment 和前后台状态；确认 canonical cover State 不被销毁，成功封面不会因 presentation rebuild再次请求。

本文件覆盖用户要求的全部产品、性能与来源验收；112项有效状态只读`docs/IMPLEMENTATION_STATE.json`。只验证剩余合同，修改生产前须确认新的失败及根因；更新已有文件，不新增ADR/audit、完整子审计或逐轮安装/哈希快照。保持唯一cache、NetLane、窗口/预算及真实退出边界。

## P0：Transition 首帧与切页设备闭环

- 验证拖动建立 transition 后，即使 current holder 为 0，目标页也先产生独立首帧。
- 确认目标页网络不等待 current source sealed、完整下载或 holder depth。
- 验证 transition 首帧后 current 基础水位先于 transition 深水位，且反向拖动不重建同一 identity。

## P0：Venera requestId 物理取消闭环

- 验证当前Venera isolated rhttp默认系统DNS等待中的requestId取消及物理退出，不恢复旧native owner。当前VPN不允许ZIC旁路；独立测试包/TestNetwork也未收到DNS包且解析成功对照未完成，仍未验，不以HTTP Future结束替代。Network4/Cookie8已验正文保持。

## P0：远程 Animated WebP 连续性

- 对比raw transport chunk、DownloadJob首批16KiB/后续64KiB聚合、source revision、decode batch、holder depth、deadline和present cadence；原transport/ingress/decode owner保持，holder不成为network gate。
- 若 current 仍断粮，只在 NetLane ranking、重复 request/source、partial wake、decode producer 或 upload deadline 内定位；不得恢复 FlowGate/startup-buffer、缩小 7/3 或降低速度。
- 真机连续快速前后翻页验证 VibeVenera retained-receiving语义：离开 encoded 7/3的 active receiving只降为priority 0，短时返回必须复用同一transport；queued undemanded可取消。新的current真正受阻时，NetLane bounded saturated preemption与Venera单上下文pressure-preemption应使低rank receiving让路。若仍阻塞，沿“current等待→实际占用Venera permit的requestId→runtime cancel→host response退出”定位，不再用detach即cancel制造重复下载。

## P0：后台重入生命周期

- 验证真实来源revision/carrier更新后不复用旧Reader session，并证明各代独立退休。保留当前两项idle exact-key LRU与两分钟TTL；Reader退休不销毁composition共享transfer/cache authority。
## P0：Flutter/Android 工具链闭环
- dev.228后真机验证改为直接统计`verified-transfer-acquire-alias`的join/rejection及physical state；不得再期待`verified-equivalent-promotion-takeover`。若同一强等价页仍出现独立重复physical owner，先区分“alias前已各自创建”“ambiguous existing owners”“proof尚未恢复”三类，再决定是否扩展TransferKey coverage，不恢复artifact promotion observer。
- dev.211真机验证：冷启动Reader继续不得等待source-version resolver；已有mapping时应先出现`version-artifact-equivalence-restored`。让相关版本在另一Reader仍存活时继续promote新artifact，旧版后续未启动页应出现`verifiedEquivalentReuse=true`并直接走artifact cache，不要求退出重进再次扫描。E-Hentai旧版confirmed successor的`!`继续验证。partial保持durable inactive边界，并在续传trace看到validatorless overlap验证而非继承旧ETag。
- 补齐纵向active拖动、拖动→惯性（ballistic）交接的真机视觉连续、输入延迟与最终呈现证据。进入条件为普通Profile/Release与有效physical-display证据；forward future/reverse prefix/scrub及applied-layout合同保持，只有fresh失败证据才重开已验几何。
- 真机优先验证 dev.206 ownership：快速退出/重进同chapter应直接复用retained PipelineReaderSession，不出现partial durable store/restore；只有session真实evict/dispose后新session才出现`session-partial-handoff` restored且`downloadStarted.committedLength>0`。已有partial动画重入必须从frame0立即播放，约30帧循环继续只属于DecodeSession。Venera cold resolver应不再出现Kotlin HttpURLConnection owner，并验证requestId cancel、Cookie/manual redirect与resolver rhttp复用。
## P1：漫画源、过滤与详情预览设备闭环
- 真机验证 Mihon Popular/Latest 与 Venera 多 explore/category section 的顺序、分页和 section identity。
