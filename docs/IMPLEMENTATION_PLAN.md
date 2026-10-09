- P0：RMR-037继续连续手势/输入延迟、GC/入口CPU及最终显示验收。用户确认自动锁屏吞首次模拟触摸，现永不自动锁屏；导航无效先核对Keyguard及fresh XML，单次无效不证明产品/输入故障。ACTION_CLICK普通路由保持，不能代替连续手势/性能。融合locator候选已撤回，不凭API推测收益或跳过兼容；原加载/固定顿挫、RMR-038与Plan039/040真实来源开放，保留NetLane、7/3和2/1。
- P0（dev.325）：补固定位置顿挫与current role promotion的真机视觉/最终呈现关联。保留已满足static decode与ready retained static upload的owner-local no-op合同，使用`analyze_current_role_boundary_jank.py`分离边界reconcile、`uploadStarted`与最终composition。current中心判定、startup artifact-pressure、7/3、decode2/1、current±2、bridge及dev.323 present fast path保持；只有fresh失败证据才重开已验控制面分量。
- P0（dev.324）：05:33 dev.323真机已把direction-flip附近resident static重复present从dev.322的52次降为0，但用户仍在同一固定位置顿挫；因此停止扩大presentation continuity/keepAlive或继续调bridge。现有App内证据已到边界：Choreographer/Flutter/scene motion大体120Hz且scene residual为0，Window FrameMetrics未覆盖active-scroll异常。dev.324只做observation：同一设备/位置同时抓SurfaceFlinger FrameTimeline与active layer composition/buffer/HWC证据，离线按ZIC layer统计actual-present gap、late/jank/fence/GPU composition。命中content-layer或SF jank才继续下钻buffer acquire/latch/present；FrameTimeline仍连续则转layer transform/content transaction，不再修改Reader/Pipeline行为。
- P0：补dev.282首次新OutputFrame的native呈现成本与快滑最终composition验收。保留lease零copy `platformResidentReuse=true`和exact retained static重新claim/project fast path；role重入不要求恢复旧重复present timing。首次frame独立测blit/schedule/frame timing，余下顿挫只按fresh证据定位首次visible/current frame与SurfaceProducer/compositor，不重改已验geometry/anchor或窗口。
- P0：按dev.280 scroll-stable geometry的现行合同补真机视觉验收：保留painted extent；允许视口之外forward ratio预备、reverse prefix原子anchor校正及slider真实visible ratio采用。物理观察只用已布局geometry，剩余ratio在idle latest-wins提交。已验组件见ADR0330/0361与loading审计；不得恢复active全冻结或逐ratio jumpTo。
## P0：Current / Previous 真实执行槽真机闭环
- dev.192 持续传输归因先对齐consumerPacing/body-read permit的停驻区间与实际读取区间，再比较`sourceRhttpProgressMaxGapMicros/sourceRhttpProgressLeadBytesMax`及`sourceRhttpBodyMaxGapMicros/maxChunkGapMicros`。当前receive-progress来自限频Dart onData，并非独立socket/Rust时钟；共同长gap不能单独归因源/CDN，FFI交付与真实网络接收仍须独立分辨，不以诊断驱动scheduler。
- 补dev.186真实Reader previous660→780到`downloadStarted`的时序；selected runtime previous pressure已验。780沿原gate请求低40分active invocation取消，JS finished与已接纳native call均退出后才可交出permit，`maxActive`保持1。
## P0：迁移 / 同源版本 / 更新提示真机闭环

- 用真实存在章节 `sourceUpdateAt` 或 projected confirmed successor relation 的书架 source card，确认右上显示独立感叹号。点击同源更新提示应直接打开来源确认的最新 successor，不得把 successor 自动加入书架。
- 从普通入口完成真实同源版本及跨源搜索/手填原生ID的确认迁移；Mihon原生URL比较及原详情41章无重复已验，确认事务仍开放。sequence-only不复制状态；覆盖实际来源artifact/metadata/cleanup callback内部中断与schema11 journal幂等恢复。
  `metadataCommitted` 后无需目标源在线，只继续旧 source cleanup；journal phase不得触发Home projection revision。真实来源/普通入口证据须与隔离事务phase-boundary及callback内部中断证据分别登记。
- 真机验证 E-Hentai/Venera 迁移后的 raw locator、canonical identity、SavedComic/偏好别名：迁移到 successor 后旧 raw alias不得继续显示书架标志，状态及 artifact 提交保持对应版本身份。

## P0：Artwork 生命周期与更新语义真机闭环

- 使用原始报障 trace 中曾“durableCacheFile → FirstFrame → 数分钟后 DecodeFailed”的同一批封面复测；在首页/Reader往返、内存压力和 response cache trim后，既有 ImageProvider必须继续显示，不得因为 cache-owned `.bin` 被删除而悬空。不得恢复 presentation retry/evict/watchdog。
- 普通主入口用来源实际确认的同源successor验证Home版本更新筛选；以home-update-shelf-admission审计中的当前筛选/metadata/progress合同为基线，不因父项partial改写已验行为。
- 普通主入口验证真实来源版本首次入架确认既有chapter/version通知、后续successor仍可提醒；隔离来源验收不得代替真实版本发现流程（ADR0383 Provisional）。

## P0：WNACG HTTP 媒体与终止失败真机闭环

- 用 `mihon:6551136894818591762` 重新打开 WNACG 列表、详情和 Reader，确认 `http://img*.wnimg*.ru/...` 封面与正文由原 source request成功返回；不得新增域名白名单、URL改写或第二 transport。

## P0：网络 UA / client / cache ownership 真机闭环

- 继续验其它transport/partial动画、真实origin/其它Mihon客户端与teardown；真实WNACG1.6受控GET/redirect的正文、原生呈现、冷READY和取消边界见source-mihon-client-pipeline审计。完整输入/canonical整块物化、live stream/backpressure及分配另验，保持原body/cache/NetLane/retry owner。


## P0：Mihon目录、Venera生命周期与图片网络设备闭环

- Roumanwu：复取历史exact 80章真机样本，核对raw SManga与升级/旧durable manifest刷新路径；不得用当前42章样本或JVM80对象合同替代原样本验收，见source-contract-acceptance审计。
- 禁漫天堂：升级后确认durable details/chapter cache revision触发真实刷新；历史单个完整 `SChapter` 分支仍需保留原对象并采集trace，不以当前350章或无durable cache的fresh探针替代。Cloudflare不调整。
- 绅士漫画：先取得保留自定义响应/镜像/压缩语义的请求级证明，再验证cover/page直连与 `sourceMediaProtocolMismatch` fallback；不得扩大标准client白名单或改设置使验收通过。
- Venera：镜像修改及完成Web登录后确认原active source/session保持。两源普通设置原地修改、9个混合插件/原11源及真实32-session边界已经验收；不再重复该容量/普通设置分支。

## P0：Cloudflare会话、详情路由与插件恢复设备闭环

- 在发生“验证接近完成又重新开始”的设备上确认验证 WebView使用 provider真实 UA；导出 handoff snapshot UA与 Mihon首个重试请求 UA，必须一致。若 challenge仍循环，继续检查 TLS/IP/站点策略，不得重新伪造 UA。

## P0：Mihon 插件识别设备闭环

- 绅士漫画：补非空Cookie/POST的真实request-plan覆盖，并验证保留自定义client语义的host直连可读正文；现有GET/Referer/UA/null-body和runtime解码不能替代这些条件。
- 已激活插件连续执行 WebView验证、设置修改和同包更新；故意让 replacement activation失败，旧插件必须继续出现在 activeSources并可请求。
- 只补真实 Mihon APK 的 `@string/...` metadata 与多入口 class解析，核对资源解析、extensionLib及每个class；已验direct单入口/Factory不重跑，也不能代替这两个真实输入。

## P0：身份、同源更新与验证设备闭环

- 使用真实 Venera/E-Hentai successor 检查详情“有新版本”、统一比较确认和 Reader 首次提醒；确认换 successor 后再次提醒。
- 在普通入口使用真实同源版本复验章节对应关系：title+sequence exact confidence仍须校验目标原生身份；sequence-only 候选不复制阅读状态或 artifact。
- 禁漫天堂仅余真实`challenge-error-*`/typed interceptor、脚本-only/普通403、可见challenge期间停留及真实解题后handoff。081已验普通完整页面稳定返回、取消/中断和一次snapshot提交，不重复；不得要求新`cf_clearance`作为唯一成功条件。
- 使用真实 Mihon 1.4/1.6扩展验证宿主调用顺序：1.6先 `getMangaUpdate(...fetchChapters=true)` / `getPageList(SChapter)`，1.4仅能力缺失时回退 legacy。用禁漫天堂确认 source返回的每个完整 SChapter原样保留且不按相同 URL折叠；Roumanwu原80章不得再因错误入口刷新成0章。

## P0：来源投影、Cloudflare 与封面身份设备闭环

- 对禁漫天堂执行强制刷新，确认只有真实 Cloudflare challenge 产生 `sourceVerificationRequired`；普通 403/timeout/解析错误保持原分类，主/兼容 interceptor 行为一致。
- 完成一次手动或自动验证后故意保持 runtime失败，再连续点击刷新/重试，确认不会再次自动跳 WebView；手动“网页验证”仍可重复打开。

本文件覆盖用户要求的全部产品、性能与来源验收；112项有效状态只读`docs/IMPLEMENTATION_STATE.json`。只验证剩余合同，修改生产前须确认新的失败及根因；更新已有文件，不新增ADR/audit、完整子审计或逐轮安装/哈希快照。保持唯一cache、NetLane、窗口/预算及真实退出边界。

## P0：Venera requestId 物理取消闭环

- 验证当前Venera isolated rhttp默认系统DNS等待中的requestId取消及物理退出，不恢复旧native owner。当前VPN不允许ZIC旁路；独立测试包/TestNetwork也未收到DNS包且解析成功对照未完成，仍未验，不以HTTP Future结束替代。Network4/Cookie8已验正文保持。

## P0：后台重入生命周期

- 验证真实来源revision/carrier更新后不复用旧Reader session，并证明各代独立退休。保留当前两项idle exact-key LRU与两分钟TTL；Reader退休不销毁composition共享transfer/cache authority。
## P0：版本等价与纵向性能真机闭环
- dev.211真机验证：冷启动Reader继续不得等待source-version resolver；已有mapping时应先出现`version-artifact-equivalence-restored`。让相关版本在另一Reader仍存活时继续promote新artifact，旧版后续未启动页应出现`verifiedEquivalentReuse=true`并直接走artifact cache，不要求退出重进再次扫描。E-Hentai旧版confirmed successor的`!`继续验证。partial保持durable inactive边界，并在续传trace看到validatorless overlap验证而非继承旧ETag。
- 补齐纵向active拖动、拖动→惯性（ballistic）交接的真机视觉连续、输入延迟与最终呈现证据。进入条件为普通Profile/Release与有效physical-display证据；forward future/reverse prefix/scrub及applied-layout合同保持，只有fresh失败证据才重开已验几何。
