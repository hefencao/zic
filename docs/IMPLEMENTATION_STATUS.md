# Implementation Status

源码版本：0.31.0-dev.328
App build：0.31.0+328

本文件只描述当前源码快照和验证等级。历史见 CHANGELOG.md，单轮证据见 docs/audits/。
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
- 本地准备：设立 physical-local-prepare 并限定 local-prepare operation 上限为 max2。
- 零拷贝读取：冷启动 cold partial 读取通过 SQLite 索引与文件直接裁决，不向 durable store 随意 materialize durable-store。
- 断点恢复：保持 SourceEpoch、generation 与 frameUploaded / decode/upload 代际一致，提供 recoverable canonical partial。
- 资源会话：支持 media-empty 状态恢复，提供 residentBodyBacked 权威正文与 range hydrate256KiB 预热。
- 元数据权威：由 physical source metadata 提供 generation-local metadataPrefix 保证。

### Home 组合与服务代际
- 生产根页面已收口为 `HomeShell` / `home_shell_*`；旧 `DemoHome` 命名只允许出现在历史 ADR/audit 记录，不能再作为当前生产入口或 owner 名称。
- `HomeShell` 只持真正的 Navigator/presentation 与 composition wiring；library/download/queue 当前 authority 继续由 `HomeLibrarySession` 持有，Reader/source/download/version 等长期职责继续由各自 Home owner 承担。
- Reader 覆盖态、Download Manager 单实例槽和 comic identity route lock 已进一步抽到纯 Dart `HomeRouteAdmission`；它不持 Navigator/UI 或任一 subsystem authority。
- Download Manager 自动缓存 projection 已区分 exact storage identity 与 display metadata：旧 source revision 复用当前同逻辑章节的人类标题并标记为旧版本页面缓存，UI 不再暴露 opaque Mihon identity/raw source id/Exact/Canonical 字段；旧 revision 只可清理，不可直接转为当前手动下载。
- 自动缓存 projection 进一步收口为 durable inventory only：Reader hot/source-resident session 不再被误计为缓存；本地 `content://` 图册普通读取保持 source-backed、零 artifact write，不会因 Reader session retention 再生成自动缓存项或正文副本。
- 书架管理/批量选择的 managing、batch 与 source-aware identity selection 已收口到纯 Dart `HomeShelfManagement`；删除/移动/归档等真实 mutation 和 dialog 仍留在 UI/既有 owner。
- 显式同源版本查看使用的 `originComicId + reuse-preparation Future` 已从 `HomeShell` 移入 `HomeVersionReuseLifecycle`；UI 只负责 route 前 start / finally finish，Reader preparation 从同一 lifecycle 查询 selected target token。
- durable service generation adoption 已从 Widget State 抽到 `HomeServiceAdoptionCoordinator`：single-flight adoption、同代 cache binding、source-resource rebind 与 source projection commit 在非 UI owner 中完成；dispose 先 fence 新 adoption，再 drain 已接纳工作。

### 外部插件运行时 (Mihon & Venera)
- Mihon 1.4/1.6 versioned ABI asset 已共享 canonical `UncaughtExceptionInterceptor`、`UserAgentInterceptor`、`CloudflareInterceptor`；
  两套 `NetworkHelper.client` 保留 default-client 类型合同，同时 Cloudflare 行为继续委托 `network_bridge` 唯一 owner。
- 真实肉漫屋扩展 APK 的 default-client guard 已核对：要求上述三类存在且 Brotli 不存在；对应 contract test 已进入 `tool/check.sh`。
- 同一扩展 bytecode 的 Injekt 请求已核对为 `Application` + `Json`；host 现按 Mihon `AppBindings` 注入
  `Json { ignoreUnknownKeys=true; explicitNulls=false }`，并把 `Json` 纳入 common-runtime 完整性预检。
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
  terminal Reader refresh 仍只由当前失败页触发，但 fresh chapter 的 matched page carriers 现在按稳定 page identity 原子换代并保留旧 page order，
  不再把失败页单独 splice 后制造同一 `sourceRevision` 内的新旧 generation 混合。

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
  preference 使用 `gestureActions.singleTap` 分层；PageHost 仍负责单击/双击/长按消歧，双击与长按没有被九宫格接管，为后续各自独立九宫格保留边界。
  Reader 顶部保留强制重载直达按钮；本漫画阅读设置已移到底栏阅读设置图标，右上杂项收纳全局阅读设置、点击设置、来源 WebView 与系统浏览器入口。
  Reader 新增按 mode 独立的“连续阅读”：只控制章节边界 UI traversal，不控制预加载。章节仍一章一个 immutable manifest/session；实际跨章前 flush progress 并通过 HomeLibrarySession 持久确立目标章。
  章节 logical previous/next 现按 sequence 升序定义，不再继承详情/source chapter 的展示顺序。continuous 以真实 ScrollPosition 首/尾作为边界 authority，边界后的单指 pointer pull 决定是否提交；短末页时 coverage-current 仍为倒数第二页也不会阻断 next。
  layout/ballistic ScrollNotification 不再同步写 UI ValueNotifier；沿既有 post-frame observation owner 发布，已消除实机跨章时 `Build scheduled during frame` → `_dependents.isEmpty` 连锁红屏。
  相邻章 preparation 的 null/error 不再永久留在 route coalescing cache，瞬时 Venera/source 失败可在后续 pull 重试。实机 `venera:jm`“唬爛也冇關係”已验证列表 6→1 显示时第5话底部仍进入 logical next 第6话；Trace 为 sequence 4→5 且无 chapter taskFailed。
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
- 静态竖排功耗报告已于 2026-09-24 重新按当前 owner 链复核：idle 恢复 3/7 static warm 是既定资源平滑策略，不作为功耗缺陷移除。
  Plan 会同时声明 one-frame intents，但真正 decode 仍由 `StagedDecodeRefillPolicy` 每次选一个 refill；Reader profile 的 bounded lanes 不等于整窗同时执行。
- ratio“逐页整树颠簸”报告部分过时：`reader_runtime` 已按 Flutter frame 合并 source-canvas ratio 发布，decoded raster 不能覆盖已知 source-canvas geometry。
  未取得 fresh trace 证明仍有跨多 frame 的 source-canvas storm 前，不再增加 debounce/Reader-local 几何旁路。
- 初始 6-screen `cacheExtent` 到首个 ScrollEnd、nominal `current±7` KeepAlive 与每 frame 最多 3 页的 idle recenter 均保留为 composition 策略；
  它们不扩大 Pipeline 资源窗口，offscreen subtree 由 `TickerMode` 静音，暂不按泄漏/功耗 bug 处理。
- 已确认并修复的额外成本：Dart `verticalSceneMotion` RenderBox/global-matrix probe 现在与 platform cadence probe 共用
  `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS` opt-in；普通构建不再运行该纯诊断逐帧采样。fresh Profile/Release 功耗复核仍可继续。

## 3. 验证矩阵
| 检查项 | 状态 | 说明 |
|---|---|---|
| repository / documentation / Dart 静态门禁 | Verified-static | 门禁与目录结构核对通过 |
| 架构合同与生命周期 | Verified-static | Reader/Pipeline/Sessions 边界已验证 |
| 自适应阅读来源先验 | Verified-device | model v8 一次性 3 页以内几何判定、异常切片中性区、双向条漫置信迁移/持久化/UI、Venera adaptiveType runtime 投影及方向/长按分流均有 focused contract；肉漫屋《要成為男子漢》真机复核为 vertical / 70.83% / samples=3 / modelVersion=8，继续停留后 samples 仍为3 |
| Reader 设置与系统栏 | Verified-device | Android 16 / targetSdk 36 真机验证 status bar 显示/隐藏、控制栏独立导航栏行为、Reader exit 恢复；漫画级 adaptive 与手动覆盖入口也做了真机 UI 验证 |
| 跨平台桥接与平台编译 | Verified-toolchain | Kotlin 与 Android 依赖通过 |
| 设备性能与真机回归 | Verified-device | 基础链路真机采样验证通过 |
| 未集成组件与缺省归档 | Unverified | 部分外部归档与端到端链路未覆盖 |
| 当前特性交付与状态 | Implemented | 核心功能均已落盘实现 |
