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
- Mihon runtime-transform locator 已升级到 payload-bound v3：`mihon-runtime-transform-v3:<payload-sha256>` 同时携带稳定 chapter/page replay 坐标与 producer payload authority。
  v1/v2 均视为 legacy；当前安装 payload 与 persisted v3 revision 不一致也会在 Reader/下载入口先强制 refresh。真实 trace 中旧 locator 的 runtime HTTP 404/source transform failure 会绕过 generic semantic recovery；
  当前修复将这类**非网络** source-owned failure typed 为 plan-replay eligible，而 SSL/EOF 仍由 DownloadJob 网络重试。
  无 replacement、replay source failure 或 replacement 再次同类失败统一收敛为 terminal source-generation handoff；
  Reader 当前页、章节下载命令和 whole-comic queue 只在各自既有 owner 内做一次整章 refresh，网络/verification/cancel 不被误分类。
- 显式 Mihon resource generation refresh 使用 `freshGeneration=true` 重取 page list；runtime 现在按 source+locator 保留 fresh source request authority，而不只是给 Dart 的 plan 投影。
  ordinary replay 的 replacement authority 只供紧随其后的 runtime load 一次性消费，fresh generation authority 则供 resolve/re-resolve/load 共用；实际取图继续走 source client，完整 method/headers/body/interceptor/cookie 不降级。
  source setting mutation 会同步失效该 source 的 retained fresh/replay state；旧/跨 payload 持久 locator 由 Reader/下载入口强制刷新后再消费。
  terminal Reader refresh 仍只由当前失败页触发，但 fresh chapter 的 matched page carriers 现在按稳定 page identity 原子换代并保留旧 page order，
  不再把失败页单独 splice 后制造同一 `sourceRevision` 内的新旧 generation 混合。

### 渲染与几何 (Pipeline & Reader View)
- 自适应阅读：`reader_runtime` model v6 将近方形切片降为低信息，以距 1:1 的比例距离增强普通分页证据，并保留极长纵幅条漫证据。
  `AppPreferencesController` 按 `sourceId` 唯一持久化 0–1 条漫置信（0=强页漫、0.5=中性、1=强条漫），
  经 `ReaderSessionSettings` 只读投影给分类器，非中性值参与 profile fingerprint；旧单向 weight 按 `0.5 + weight/2` 兼容迁移。
  Venera `comic.adaptiveType` 已由 typed source descriptor 接入 classifier，来源名/官网也由 App composition 投影。
  adaptive profile 现在重新作为跨行为输入：无显式方向时可选择方向；长按放大按漫画显式覆盖 >
  adaptive 类型建议 > 模式默认解析（条漫默认关，页漫/动图默认开）。显式方向不再停止 profile 更新，
  为后续翻译等消费者保留同一结果，同时不改变 Pipeline/NetLane owner。
  来源级应用策略已统一收口到齿轮“源设置”：条漫置信、source-scoped 数据信任、来源独立下载目录；
  configurable source 自身设置/登录改为“来源属性与登录”。每漫画“使用自适应设置”独立于手动设置 master，
  阅读方向只保留跟随/LTR/RTL/纵向；“启用本漫画覆盖”只控制手动覆盖，清除覆盖不再清 adaptive policy/profile。
  全局分页方向为 LTR/RTL/跟随来源，默认 LTR；纵向拼接、长按放大等离散项使用互斥胶囊。
  阅读设置已按布局、界面、双击操作、长按操作、缩放质量拆分；长按倍率独立于双击倍率，默认 2.0x。
  系统状态栏可见性独立于 Reader 控制栏。Android 16 / targetSdk 36 使用 reader_runtime 原生 WindowInsetsController owner；Reader 退出恢复系统栏。
- 页面几何：ValueListenable 提供 pageDimensions 驱动的 ratio live feed 投影。
- 纵向模式：vertical模式只有extent真实变化 才能触发 anchor/geometry rebuild；vertical模式 保持布局稳定。
- 视口与上传：vertical hidden-upload规则不变；明确区分 source-canvas 与 decoded raster 职责。
- 原生纹理呈现：以 presentationIdentity 标识 resident surface，接入 Android SurfaceProducer。
- 缓存与淘汰：promoted LRU=8 维护热尾淘汰，当前 current 拥有最高抢占权威。

## 2. 当前开放问题
- 静态竖排功耗偏高：HeuristicPolicy 静态全量并发上传与逐页异步尺寸重绘引发整树颠簸。
- 纵排初始化 cacheExtent 保持 6 屏与 15 页 KeepAlive 常驻未收敛。

## 3. 验证矩阵
| 检查项 | 状态 | 说明 |
|---|---|---|
| repository / documentation / Dart 静态门禁 | Verified-static | 门禁与目录结构核对通过 |
| 架构合同与生命周期 | Verified-static | Reader/Pipeline/Sessions 边界已验证 |
| 自适应阅读来源先验 | Verified-toolchain | model v6 比例回归、双向条漫置信迁移/持久化/UI、Venera adaptiveType runtime 投影及方向/长按分流均有 focused contract；具体线上来源尚未标记真机验证 |
| Reader 设置与系统栏 | Verified-device | Android 16 / targetSdk 36 真机验证 status bar 显示/隐藏、控制栏独立导航栏行为、Reader exit 恢复；漫画级 adaptive 与手动覆盖入口也做了真机 UI 验证 |
| 跨平台桥接与平台编译 | Verified-toolchain | Kotlin 与 Android 依赖通过 |
| 设备性能与真机回归 | Verified-device | 基础链路真机采样验证通过 |
| 未集成组件与缺省归档 | Unverified | 部分外部归档与端到端链路未覆盖 |
| 当前特性交付与状态 | Implemented | 核心功能均已落盘实现 |
