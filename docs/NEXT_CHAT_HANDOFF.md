# Next Chat Handoff

## 1. 唯一继续基线
- 稳定基准版本：`0.31.0-dev.328` / App `0.31.0+328`。
- 历史阶段基线验证覆盖：dev.196, dev.197, dev.198, dev.199, dev.203 bounded 抢占基准。
- 当前主任务：Home 生产组合已由 `DemoHome` 收口为 `HomeShell`，并把 durable service adoption/cache-generation commit 抽到非 UI `HomeServiceAdoptionCoordinator`；后续 Home 改动继续沿现有 owner 边界拆分，禁止把 service/Reader/source authority 收回 Widget State。
- 功耗审计基准：静态竖排阅读高功耗根因已定位，详见 `docs/audits/static-vertical-active-probe-2026-09-22.md`。

## 2. 必读顺序
1. `docs/DOCUMENTATION_POLICY.md`：文档职责与证据等级；
2. `AGENTS.md`：架构边界与无修改/最小修改规则；
3. `docs/ARCHITECTURE.md`：当前系统所有权与生命周期；
4. `docs/SPEC.md`：产品与工程长期规范；
5. `docs/IMPLEMENTATION_STATUS.md`：当前实现与验证矩阵。

## 3. 当前开放问题
- Home shell 已继续抽出纯状态 `HomeRouteAdmission`（Reader 覆盖、Download Manager 单实例、comic identity route lock）和 `HomeShelfManagement`（书架管理/批量选择）；
  selected version-view preparation 也已归并到 `HomeVersionReuseLifecycle`，`HomeShell` 不再持 version preparation map。
  navigation/source-search 与 picker/trace-export busy flag 经复审仍直接服务当前 Scaffold/route intent/async UI operation，暂不为“瘦身”强抽 owner。
  后续若继续瘦身，应从明确重复状态或 route builder adapter 入手；禁止新增跨 owner facade，也禁止把 service generation / route admission / version preparation / shelf selection 镜像回 `HomeShell`。
- 静态竖排浏览功耗偏高（HeuristicPolicy 静态爆发上传、逐页尺寸异步重绘颠簸、首屏 6 屏大 cacheExtent、KeepAlive 15 页常驻与 scheduleFrame 调度）。
- 文档超长单行整理，严格保持 handoff/status 责任预算上限，杜绝单行堆砌历史。

## 4. 下一步命令
- `python3 tool/check_repo.py`
- `python3 tool/check_documentation.py`
- `tool/check.sh`

## 5. 不可改变的稳定边界
- 自适应阅读由 `reader_runtime` 单一分类器生成共享 profile，消费元数据/页面几何/实测动画、typed source adaptive hint，
  以及 `ReaderSessionSettings` 中只读的来源条漫置信；来源置信只由 `AppPreferencesController` 按 `sourceId` 持久化，
  0/0.5/1 分别表示强页漫/中性/强条漫。Venera `comic.adaptiveType` 经 typed descriptor 投影，Mihon 无声明时保持 unknown。
  model v8 的页面几何最多采样 3 张并包含第一页；达到目标样本数后只判一次，后续页面不得重算 profile。
  `0.65 < h/w < 1.20` 的异常/transport-slice 比例不得形成页漫票，因此 720×700、720×500 不能仅凭尺寸被判成页漫。
  真机肉漫屋《要成為男子漢》已验证：50% 来源置信 + `韓國` + 异常切片得到 vertical 70.83%、samples=3、modelVersion=8，持续停留后 samples 不增长。
  漫画级显式方向只覆盖方向，不能阻止 profile 继续驱动其它行为；
  当前长按放大按“漫画显式覆盖 > adaptive 类型建议 > 模式默认”解析，条漫默认关、页漫/动图默认开。
  全局/漫画级 adaptive 开关独立于手动 override master；Reader 不得复制来源设置 authority，也不得借 adaptive 接管 Pipeline 调度。
- 来源管理中的齿轮只表示 ZIC “源设置”：条漫置信、source-scoped 历史缓存冲突信任、来源独立下载目录。
  旧 plugin-scoped trust 的 source 迁移只有在 installed record 能证明 source 集完整时才退休 plugin fallback；runtime discovery 不完整时必须继续保留。
  configurable source 自身属性/登录使用属性列表图标“来源属性与登录”；插件管理只负责插件生命周期，不再承载 source policy。
  每漫画“使用自适应设置”是独立开关；手动阅读方向只有跟随/LTR/RTL/纵向，
  “启用本漫画覆盖”只 gate 手动方向/纵向拼接/长按放大/阅读顺序等 override，开启后 adaptive 入口仍保留；清除手动覆盖不得清 adaptive policy/profile。
  全局分页方向为 LTR/RTL/跟随来源且默认 LTR；阅读设置按布局、界面、双击操作、长按操作拆开，双击一级/二级倍率都使用 slider，长按倍率独立于双击倍率并默认 2.0x。
  系统状态栏为 `显示 / 隐藏 / 跟随控制栏` 三态且默认显示；follow 模式直接复用 Reader 控制栏可见性。Android 16/targetSdk 36 由 reader_runtime 的 WindowInsetsController owner 实际 show/hide，navigation bar 仍跟随控制栏，Reader exit 恢复系统栏。
- 页面网络调度由共享 `NetLane` 唯一拥有，保持 normal 5 + current 高优先级保留槽 1（5个transport lease 与 current handoff）。
- 逻辑与解码窗口固定为前 7 / 后 3（7/3）及解码前 2 / 后 1（2/1）。
- Reader 仅消费不可变输出，不拥有 transport、session、cursor 或 texture。
- 传输租约竞争采用 ranked-transport-lease-reclaim；支持 active current-class demotion 与 新current waiter 的 40分 差值抢占。
- 物理准备限制在 max2 并设立 post-local network-admission rank barrier，在任何 NetLane task 启动前执行 physical-local-prepare，0-byte victim 自动重排 local prepare。
- 存储与缓存：支持 cold partial 与 verified-equivalent READY 复用；保持 SourceEpoch、generation 与 frameUploaded / framePresented 的代际单调性。
- rhttp transport不得再次增加64/256 KiB聚合；DownloadJob 为单一数据聚合 owner。
- Mihon 1.4/1.6 `NetworkHelper.client` 必须保留 canonical default-client 三件套：首位 `UncaughtExceptionInterceptor`、
  `UserAgentInterceptor`、以及委托 `network_bridge` 的 `CloudflareInterceptor`；默认 client 不加 Brotli。这是 plugin-host ABI 兼容边界，
  不得把这些兜底/验证语义迁到 Reader/Pipeline/Download。Mihon Injekt scope 同样由 plugin host 唯一拥有；`Application`、`NetworkHelper`、
  `Json(ignoreUnknownKeys=true, explicitNulls=false)` 为当前稳定 host singleton 合同。
  Mihon 新生成的 opaque page locator 都携带 stable chapter/page replay 坐标；host-direct plan 另有 `directPlanReplay`，可在 host transport failure 后沿现有一次性 source recovery 重取 page list。
  runtime-owned `mihon-runtime-transform-v3:<payload-sha256>` 仍只有非网络 source failure 可发布 replay eligibility，SSL/EOF 继续归 DownloadJob；payload-bound revision 继续绑定实际 extension payload。
  升级前缺 replay 坐标的普通 `mihon:resource:` 持久 locator 由 source-compat gate 识别并在消费前刷新，不要为它引入 sourceRevision/version churn。
  payload-bound revision 会让旧 exact automatic-cache generation 合法留存；Download Manager 必须把它视为 historical cache identity，
  仅从当前同逻辑 chapter 复用 display metadata，禁止解析/展示 opaque Mihon id，也禁止把旧 revision 直接转成当前手动下载。
  自动缓存 projection 现为 durable-inventory-only：Reader/transfer runtime 的 hot session 不可单独建立 cache row；`local-folder` 的 `content://` source-resident promoted body 普通重读保持 source-owned，不物化 app-owned duplicate，Reader 关闭后 retention 也不会让它重新出现在自动缓存。
  v1/v2 或 payload SHA 不匹配的 v3 locator 必须在 Reader/下载入口强制 source refresh，不得恢复旧 opaque plan；replacement unavailable/replay source failure 只交给既有
  terminal source-generation refresh handoff，Reader 当前页、章节下载命令与 whole-comic queue 各自在原 owner 内至多整章刷新一次；
  不在 Reader/Pipeline 新建 Mihon retry owner。显式 `refreshResource` 用 `freshGeneration=true` 重取 page list，并由 runtime
  在当前 generation 内按 source+locator 有界保留 fresh source request authority，resolve/re-resolve/runtime load 不得回退旧 opaque plan；source setting mutation
  推进 transport generation 时必须同步失效该 source 的 retained fresh/replay state。
  两份 Android `FallbackDns` 已统一为系统 DNS authority 优先且不重排；只有系统失败/空才使用 public A+AAAA fallback，并交错双栈结果。不要把 public-only 过滤施加到系统 DNS，以免破坏 split-DNS/private host。
- VeneraHttpCacheStore 维持 6h 有效期与 targeted force-miss 规约；Venera 阶段约束见 0169-venera-previous-request-plan-pressure-and-source-open-stages.md。
