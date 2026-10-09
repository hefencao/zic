# Next Chat Handoff
## 1. 唯一继续基线
- 稳定基准版本：`0.31.0-dev.328` / App `0.31.0+328`；历史兼容基准仍覆盖 dev.196、dev.197、dev.198、dev.199 与 dev.203 bounded 语义。
- 当前112项：device75/toolchain11/superseded2/partial18/pending6，24条未完成记录。039四类Home筛选/049正文载体/099实际canonical收口；首次入架、client变体及性能独立开放。052/020/TTL/LRU保持；097真实代际、016/wire013/DNS089及原加载/输入/最终显示开放。
- 跨章3.53–3.80s已由Home日志归因每次两次494–495章authority重建；RMR-036保留完整payload比较与真实locator更新，消除无变化/重复重建，86项owner、2148项全门禁及四次跨章首尾通过（ADR0357 Accepted）；after12–20ms但hydrate规模较小，不作同规模加速结论。功耗基准仍为static-vertical-active-probe审计，platform/scene probe仅显式诊断启用。
- 功耗审计基准：`docs/archive/audits/static-vertical-active-probe-2026-09-22.md` 已关闭常驻 platform cadence probe；2026-09-24 复核其他AI报告后，进一步把 Dart `verticalSceneMotion` RenderBox矩阵probe并入同一显式诊断开关。
## 2. 必读顺序
1. `docs/DOCUMENTATION_POLICY.md`与`AGENTS.md`：文档证据、架构边界及修改规则；
2. 依次阅读`docs/ARCHITECTURE.md`（当前所有权与生命周期）和`docs/SPEC.md`（产品与工程长期规范）；
3. `docs/IMPLEMENTATION_STATUS.md`与`docs/IMPLEMENTATION_STATE.json`：当前实现、唯一有效状态及剩余验收；归档只在追溯具体决定时按需读，不据旧待办修改生产。
## 3. 当前开放问题
- Home卡片source signal/key及健康/pending artwork State保持，063/066/082收口。同生产输入2368/27suite/analyzer/Rust22、全门禁/三ABI Debug/Profile/minifiedRelease/JNI保持通过；native115保留，均非本轮重跑。本轮文档/所有权门禁通过，38 decode/55关联保持。
- 073/027/028/072/070/041已验保持。057：JM API1→2→1应用/回读通过；API2后12有效引用不变、JM代际推进/EH不变。应用后/最终恢复身份、native ID/closed及真实Web登录未验；普通设置/9插件/32会话不重跑。challenge/升级/DNS/原加载独立。
- EH predecessor/ACK与提醒开放；099受控及实际canonical已验，停止重复。31后台proof失败根因为compact focus URI泄漏；只hydrate占位focus，取消/仍占位停止，真实carrier/epoch保持。四回归/新Release371→424、Reader80静置、本地13,394,740B/0失败通过。
- rhttp取消与borrowed reset保持。DecodeSession补same-epoch实例校验及新frame0前清旧续帧floor，晚帧丢弃/typed cancel、cursor等原Future。四分支先失败、38 decode/55关联及实际native换源/同prefix重建/新Texture通过，0失败；隐藏同源fill保持。097真实代际及016/client/原加载其余开放。
- 0395/0396/0397与JM index3、TTL/LRU/used texture/active decode/prepare/pending present保持。prepare原Future重入1/12已验，另11未覆盖；631事件/0失败/0重读。005复用020新frame blit3087us/schedule1313us/deadline0；快滑视觉/GPU与真实代际开放。19话原APK/官方1.6.22 provenance保持。
- Home shell 的route admission与书架管理分别归 `HomeRouteAdmission`、`HomeShelfManagement`；selected version-view preparation归 `HomeVersionReuseLifecycle`，`HomeShell` 不持 version preparation map。
  navigation/source-search 与 picker/trace-export busy flag 经复审仍直接服务当前 Scaffold/route intent/async UI operation，暂不为“瘦身”强抽 owner。
  后续若继续瘦身，应从明确重复状态或 route builder adapter 入手；禁止新增跨 owner facade，也禁止把 service generation / route admission / version preparation / shelf selection 镜像回 `HomeShell`。
- 静态竖排功耗下一步只接受 fresh Profile/Release 证据再改行为：idle 3/7 static warm 是刻意的平滑资源分配，staged refill不会整窗同时decode；
  2026-09-24 最新可见空白Trace证明“active期间把所有hidden native-static upload都推迟到visible seam”会制造0.3–0.8s首帧债务；更深一层确认vertical曾硬禁detached output binding，导致native output已ready后仍可等PageHost约1.95–2.34s才present。
  因此active只继续defer `far/near`；既有2/1 deadline窗口的`next/next2/previous`可提前pre-present并retain，vertical real UploadDemand同时预绑定detached output consumer，仍由UploadLane/FrameBudgeter限流，不得写成扩大预加载窗口。
  首次JPEG布局另保留64B metadata ABI，并用最多64KiB的一次性dimension probe尽早发布source-canvas size。
  fresh Profile `08-55-17` 已验证16次跨页0次在正coverage后补首帧；native `outputReadyToPresent` 为53/53/88µs，page27–30 detached prewarm约提前310–510ms，详见ADR 0323。
  external-static绕过ScrollAwareImageProvider高速defer与TickerMode private keepAlive；detached-ready不得继续等待mounted resolve，eviction必须释放mounted consumer。
  managed static统一provider/只持ImageInfo，backpressure归cache owner；same identity允许regrant，resident provider禁二次wrap，无authority generation recovery已撤销（ADR0324/0335/0336）。
  6-screen bootstrap、`current±7` KeepAlive和有界recenter目前也保留。2026-09-24 已确认 source-canvas ratio live feed 会把 pending-only/future geometry 事实放大成 whole-Reader rebuild；
  现改为 pending-only 零 rebuild、真实 extent 变化只重建 vertical ListView geometry subtree，Pipeline policy 不变；逐帧displacement又把finger-down drag与ballistic拆开：无resampling平均相邻速度摆动9.9%–18.3%、最高255%，built-in resampling降到0个>20% jump、max<=0.0171%。
  ADR 0325恢复`reader_runtime` scoped ref-counted lease；旧dev.310 ballistic cadence否证仍有效，禁止调`samplingOffset`或自定义插值。下一真机同时验视觉平滑和touch latency；功耗继续先量化warm task cadence，不缩窗口/禁warm。
- 2026-09-25 后台执行链按 ADR 0328 再次收紧：并非所有 hot-path 工作都值得 worker 化。
  version candidate `Isolate.run` + prepared-demand two-phase commit、以及 source-ready 的额外 deferred queue 已撤销，恢复同步 owner-local control；Reader observation 只在同一 UI isolate 上按 frame/event-turn 让行。
  保留的 worker 都有阻塞证据：resident source hydration 旧trace median 5.835ms / p90 10.519ms / max 14.803ms，因此 native reserve/copy/file-range 继续离开 UI isolate；source-write pending queue消费原 ingress rank/cancel，decode/source-write lifecycle分离。
  SQLite authority仍由 SqliteIndex 拥有：约0.13ms的read已撤销常驻worker，直接在owner connection做单事务snapshot；touch保留worker且先过既有 StorageWriteScheduler。
  后续若再“放后台”，先区分 async scheduling 与真正 multithread/isolate：网络等待继续用 Future+NetLane；只有 CPU/同步FFI/磁盘调用会实际占 frame budget时才新增 worker，且不得复制 owner/retry/eligibility/state。
## 4. 下一步命令
- `python3 tool/check_repo.py`；`python3 tool/check_documentation.py`；`tool/check.sh`
## 5. 不可改变的稳定边界
- 自适应阅读由 `reader_runtime` 单一分类器生成共享 profile，消费元数据/页面几何/实测动画、typed source adaptive hint，
  以及 `ReaderSessionSettings` 中只读的来源条漫置信；来源置信只由 `AppPreferencesController` 按 `sourceId` 持久化，
  0/0.5/1 分别表示强页漫/中性/强条漫。Venera `comic.adaptiveType` 经 typed descriptor 投影，Mihon 无声明时保持 unknown。
  model v8 的页面几何最多采样 3 张并包含第一页；达到目标样本数后只判一次，后续页面不得重算 profile。
  `0.65 < h/w < 1.20` 的异常/transport-slice 比例不得形成页漫票，因此 720×700、720×500 不能仅凭尺寸被判成页漫。
  真机肉漫屋《要成為男子漢》已验证：50% 来源置信 + `韓國` + 异常切片得到 vertical 70.83%、samples=3、modelVersion=8，持续停留后 samples 不增长。
  漫画级显式方向只覆盖方向，不能阻止 profile 继续驱动其它行为；当前长按放大按“漫画显式覆盖 > adaptive 类型建议 > 模式默认”解析，条漫默认关、页漫/动图默认开。
  全局/漫画级 adaptive 开关独立于手动 override master；Reader 不得复制来源设置 authority，也不得借 adaptive 接管 Pipeline 调度。
- 来源管理中的齿轮只表示 ZIC “源设置”：条漫置信、source-scoped 历史缓存冲突信任、来源独立下载目录。
  旧 plugin-scoped trust 的 source 迁移只有在 installed record 能证明 source 集完整时才退休 plugin fallback；runtime discovery 不完整时必须继续保留。
  configurable source 自身属性/登录使用属性列表图标“来源属性与登录”；插件管理只负责插件生命周期，不再承载 source policy。
  每漫画“使用自适应设置”独立于手动 override master，清除手动覆盖不清 adaptive policy/profile。全局分页方向默认 LTR；`ReaderModeSettings` 分 paged/continuous，双击两级 slider 与独立长按倍率按 mode 保存。
  点击区域按当前 mode 保存；Reader 内用当前页面沉浸覆层编辑，可拖两横两竖线；grid 与真实 hit-test 共用 authority，覆层 cell 覆盖完整 viewport 截获编辑输入且不改变 ReaderView ancestry，drag 只更新 overlay-local State。PageHost 仍唯一负责手势消歧；顶部强制重载、本漫画底栏设置及杂项 Web 入口不变。
  2026-09-27 native-release Profile 重测：连续纵滑 cadence 约 8.4ms，常见 max 14.8–15.8ms；分页 8 次快速横滑 92 frames/0 janky/p95 6ms/p99 9ms。上一轮设备残留 Debug；后续性能验证保持 Profile/Release，不以 physics/刷新率/Pipeline 水位掩盖。
  canonical Venera source gate 仍单 context，仅 isolated-qualified `modifyImage` 有界为 2 个独立 WebView/Bitmap worker；历史 uncached origin completion 的 105–226ms burst 与 100–224ms transform 时长重叠，但当前实机 fresh-reload 未形成 overlap，不宣称 2×。
  ADR 0330–0334：scrub保留7/3、50ms latest-wins、center anchor与next/previous对称deadline；ADR 0334仅允许同Reader/revision三个真实viewport-visible、localOnly work使用唯一第三operation handoff，普通cap仍为2。
  最终Profile 14-33-10：visibility已收口为`ReaderObs -> DownloadDemand -> TransferDemand`；`next-current` forward n=17/reverse n=10中位均约+0.01ms，37次handoff median/max=166/1684us、active从未>3、taskFailed=0。
- 迁移统一入口/来源药丸/聚合封面标题/高级ID保持，024/025/075不重跑。023仍需实际旧卡与唯一head，46终点不证明head。已恢复Release499ee89d/PID32478、无forward；该次恢复后Home/Keyguard未复核。AOT evaluate禁用不阻断UI/trace。040/074独立。
  Download治理：下载审计JSON13/13已闭合。DL-DIR-019/017证据见`docs/archive/audits/saf-body-kill-reopen-2026-09-30.json`：真机9组kill/reopen+1组physical幂等及required-toolchain gate通过。保持唯一index和2-wide共享NetLane；禁止equal-length恢复或给普通checkpoint新增正文扫描。后续只在fresh行为证据下重新打开问题。
  native worker补位失败若仍有live worker只降级capacity并保留pending；decode单live worker仍只服务current。decode numeric rank在selection时直接读DecodeLane TaskControl，不再镜像priority/subscription。
  点击区域save绑定edit-session token，continuous真实min/max extent映射首/末页；dev.114/dev.117 refill guard已转stable stage + behavior regression；Reader Kotlin compile stub已补齐当前system-bar API，平台guard保留。
  两mode跨章开关只gate UI traversal；logical顺序消费source oldest-first投影，Mihon兼容旧opaque ordinal且不改ID。continuous真实首/尾后才pointer pull，显式入口覆盖历史并经布局回执；paged保持PageView pull，preload独立。
  章节仍一章一个 immutable manifest/session，跨章前 flush progress 并由 HomeLibrarySession upsert；系统状态栏为 `显示 / 隐藏 / 跟随控制栏` 三态且默认显示，Android 16/targetSdk 36 由 reader_runtime WindowInsetsController owner 实际 show/hide，Reader exit 恢复系统栏。
- 页面网络调度由共享 `NetLane` 唯一拥有，保持 normal 5 + current 高优先级保留槽 1（5个transport lease 与 current handoff）；逻辑/解码窗口仍为前7/后3与前2/后1。跨章节 preload 只补当前章 7/3 残余水位，不额外扩窗，同一 lease 随页推进伸缩且 priority 500 < far 520，并受共享 50MB budget；禁止 UI prefetch gate 或第二 scheduler。
- Reader 仅消费不可变输出，不拥有 transport、session、cursor 或 texture；传输租约竞争采用 ranked-transport-lease-reclaim，支持 active current-class demotion 与 新current waiter 的 40分 差值抢占。
- 物理准备普通cap=max2；保留 post-local network-admission rank barrier；NetLane task前先 physical-local-prepare；0-byte victim 自动重排 local prepare。ADR0334的visible cohort例外见上。
- 存储与缓存：支持 cold partial 与 verified-equivalent READY 复用；保持 SourceEpoch、generation 与 frameUploaded / framePresented 的代际单调性。
- rhttp transport不得再次增加64/256 KiB聚合；DownloadJob 为单一数据聚合 owner。
- Mihon 1.4/1.6 `NetworkHelper.client` 必须保留 canonical default-client 三件套：首位 `UncaughtExceptionInterceptor`、
  `UserAgentInterceptor`、以及委托 `network_bridge` 的 `CloudflareInterceptor`；默认 client 不加 Brotli。这是 plugin-host ABI 兼容边界，
  不得迁到Reader/Pipeline/Download；Injekt只属plugin host，Application/NetworkHelper/Json(ignoreUnknownKeys=true,explicitNulls=false)保持。原生/opaque漫画共用source调用、URL互斥/canonical artwork；完整manifest按raw请求缓存，raw响应ID不改。
  Mihon 新生成的 opaque page locator 都携带 stable chapter/page replay 坐标；host-direct plan 另有 `directPlanReplay`，可在 host transport failure 后沿现有一次性 source recovery 重取 page list。
  runtime-owned `mihon-runtime-transform-v3:<payload-sha256>` 仍只有非网络 source failure 可发布 replay eligibility，SSL/EOF 继续归 DownloadJob；payload-bound revision 继续绑定实际 extension payload。
  升级前缺 replay 坐标的普通 `mihon:resource:` 持久 locator 由 source-compat gate 识别并在消费前刷新，不要为它引入 sourceRevision/version churn。
  payload-bound revision 会让旧 exact automatic-cache generation 合法留存；Download Manager 必须把它视为 historical cache identity，
  仅从当前同逻辑 chapter 复用 display metadata，禁止解析/展示 opaque Mihon id，也禁止把旧 revision 直接转成当前手动下载。
  自动缓存 projection 现为 durable-inventory-only：Reader/transfer runtime 的 hot session 不可单独建立 cache row；`local-folder` 的 `content://` source-resident promoted body 普通重读保持 source-owned，不物化 app-owned duplicate，Reader 关闭后 retention 也不会让它重新出现在自动缓存。
  v1/v2 或 payload SHA 不匹配的 v3 locator 必须在 Reader/下载入口强制 source refresh，不得恢复旧 opaque plan；replacement unavailable/replay source failure 只交给既有
  terminal source-generation refresh handoff，Reader 当前页、章节下载命令与 whole-comic queue 各自在原 owner 内至多整章刷新一次；
  不在 Reader/Pipeline 新建 Mihon retry owner。显式 `refreshResource` 用 `freshGeneration=true` 重取 page list，并由 runtime
  在当前 generation 内按 source+locator 有界保留 fresh source request authority，resolve/re-resolve/runtime load 不得回退旧 opaque plan；source setting mutation 推进 transport generation 时必须同步失效该 source 的 retained fresh/replay state。
  两份 Android `FallbackDns` 已统一为系统 DNS authority 优先且不重排；只有系统失败/空才使用 public A+AAAA fallback，并交错双栈结果。不要把 public-only 过滤施加到系统 DNS，以免破坏 split-DNS/private host。
- VeneraHttpCacheStore 维持 6h 有效期与 targeted force-miss 规约；Venera 阶段约束见 0169-venera-previous-request-plan-pressure-and-source-open-stages.md。
