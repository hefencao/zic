- P0：RMR-037仅余连续手势/输入延迟、完整进退/active GC与最终显示。72b Profile06bdc2b2 Ani273正文/返回通过；保留timeline覆盖Reader帧，max GC6.019ms，完整窗口缺头尾，不证明总分配/全程性能。取得210a3115原HalfLove→Ani输入与有效物理显示条件再验；不重复静置样本、不重开已验控制面。自动锁屏/误点击及采样ring覆盖属于测试边界；融合locator候选保持撤回，NetLane、7/3和2/1保持。
- P0（dev.325）：补固定位置顿挫与current role promotion的真机视觉/最终呈现关联。保留已满足static decode与ready retained static upload的owner-local no-op合同，使用`analyze_current_role_boundary_jank.py`分离边界reconcile、`uploadStarted`与最终composition。current中心判定、startup artifact-pressure、7/3、decode2/1、current±2、bridge及dev.323 present fast path保持；只有fresh失败证据才重开已验控制面分量。
- P0（dev.324）：05:33 dev.323真机已把direction-flip附近resident static重复present从dev.322的52次降为0，但用户仍在同一固定位置顿挫；因此停止扩大presentation continuity/keepAlive或继续调bridge。现有App内证据已到边界：Choreographer/Flutter/scene motion大体120Hz且scene residual为0，Window FrameMetrics未覆盖active-scroll异常。dev.324只做observation：同一设备/位置同时抓SurfaceFlinger FrameTimeline与active layer composition/buffer/HWC证据，离线按ZIC layer统计actual-present gap、late/jank/fence/GPU composition。命中content-layer或SF jank才继续下钻buffer acquire/latch/present；FrameTimeline仍连续则转layer transform/content transaction，不再修改Reader/Pipeline行为。
- P0：补dev.282快滑最终composition与视觉验收。保留lease零copy `platformResidentReuse=true`和exact retained static重新claim/project fast path；role重入不要求恢复旧重复present timing。余下顿挫只按fresh有效显示证据定位SurfaceProducer/compositor，不重复已量化首个native output成本或重改已验geometry/anchor、窗口。
- P0：按dev.280 scroll-stable geometry的现行合同补真机视觉验收：保留painted extent；允许视口之外forward ratio预备、reverse prefix原子anchor校正及slider真实visible ratio采用。物理观察只用已布局geometry，剩余ratio在idle latest-wins提交。已验组件见ADR0330/0361与loading审计；不得恢复active全冻结或逐ratio jumpTo。
## P0：Current / Previous 真实执行槽真机闭环
- dev.192 传输归因须对齐consumerPacing/body-read permit，并独立分辨网络接收、FFI/Dart交付与应用停驻；20ms限频Dart progress共同长gap不足以归因。SDK36当前设备未注册`android.network_packets`，普通ftrace/log不能补证；取得独立wire/Rust时间观测后才采集，不重复同一无该能力设备，不以diagnostics驱动scheduler。
- 016只在真实previous660→780发生于首次`downloadStarted`前时验入场延迟与source gate。新强刷样本5 starts/0 failures，但旧正文始终active，660→0→780不能补入场时序；停止重复该输入。selected runtime pressure/物理退出已验，780沿原gate取消低40分invocation，JS与已接纳native均退出才交permit，`maxActive`保持1。
## P0：迁移 / 同源版本 / 更新提示真机闭环

- 版本动作仅在实际搜索返回在架旧版且来源关系证明唯一 latest head 时验：直接打开该 raw successor、目标仍未入架。当前 EH 标题聚合结果未返回旧版，Ani 完整图56节点/46终点；不能按日期、generation或5条saved子图补造head，不重复该不满足前提的版本动作。

## P0：Artwork 生命周期与更新语义真机闭环

- 037先恢复原封面批次：归档只识别18comic186442/195520，缺本地及另一封面；项目/私有测试目录未找到08-08原trace/dev164包。取得完整批次后验首页/Reader往返、内存压力和response cache trim下既有ImageProvider不悬空；不恢复presentation retry/evict/watchdog。
- 普通主入口验证真实来源版本首次入架确认既有chapter/version通知、后续successor仍可提醒；隔离来源验收不得代替真实版本发现流程（ADR0383 Provisional）。

## P0：Mihon目录、Venera生命周期与图片网络设备闭环

- 原19/20偶发缓存加载/重下、真实host正文/fallback、challenge/登录、partial/live媒体及完整输入/canonical分配仍独立待验；仅按剩余合同验收来源实际返回的输入，不额外要求所有协议变体。049正文载体已收口，不宣称live streaming或零分配，也不重跑已验生命周期。
- Roumanwu：复取历史exact 80章真机样本，核对raw SManga与升级/旧durable manifest刷新路径；不得用当前42章样本或JVM80对象合同替代原样本验收，见source-contract-acceptance审计。
- 禁漫天堂：仅余升级后的durable details/chapter cache revision真实刷新；fresh 350章不替代升级缓存验收。若单个完整 `SChapter` 再现，保留原对象检查；该条件分支不是必须找回的样本。Cloudflare不调整。
- 绅士漫画：补可无状态重放的真实cover/page host正文与 `sourceMediaProtocolMismatch` fallback；保留自定义响应/镜像/压缩语义，不把各变体另加为必验项，不扩大client白名单。
- Venera057仅余完成真实Web登录后的原active source/session连续性。JM API1→2→1应用/重入/恢复已验：原12引用有效、native process/session/runtime ID和未关闭状态保持，JM代际推进/EH不变；镜像、普通设置、9插件/原11源和32-session边界不重跑。

## P0：Cloudflare会话、详情路由与插件恢复设备闭环

- 在发生“验证接近完成又重新开始”的设备上确认验证 WebView使用 provider真实 UA；导出 handoff snapshot UA与 Mihon首个重试请求 UA，必须一致。若 challenge仍循环，继续检查 TLS/IP/站点策略，不得重新伪造 UA。

## P0：Mihon 插件识别设备闭环

- 绅士漫画：真实GET/Referer/UA/null-body plan与runtime解码已验；仅补符合现行host replay条件的可读正文，核对来源实际method/headers/body。空Cookie/body是有效输入，不要求来源额外产生POST；有状态/未知client仍归runtime。
- 只补真实 Mihon APK 的 `@string/...` metadata 与多入口 class解析，核对资源解析、extensionLib及每个class；已验direct单入口/Factory不重跑，也不能代替这两个真实输入。

## P0：身份、同源更新与验证设备闭环

- 使用真实 Venera/E-Hentai predecessor/ACK输入及successor补Reader首次/后续提醒；真实版本详情、比较及同源确认已验，不再重复。
- 禁漫天堂仅余真实`challenge-error-*`/typed interceptor、脚本-only/普通403、可见challenge期间停留及真实解题后handoff。081已验普通完整页面稳定返回、取消/中断和一次snapshot提交，不重复；不得要求新`cf_clearance`作为唯一成功条件。
- 使用真实 Mihon 1.4/1.6扩展验证宿主调用顺序：1.6先 `getMangaUpdate(...fetchChapters=true)` / `getPageList(SChapter)`，1.4仅能力缺失时回退 legacy。用禁漫天堂确认 source返回的每个完整 SChapter原样保留且不按相同 URL折叠；Roumanwu原80章不得再因错误入口刷新成0章。

## P0：来源投影、Cloudflare 与封面身份设备闭环

- 对禁漫天堂执行强制刷新，确认只有真实 Cloudflare challenge 产生 `sourceVerificationRequired`；普通 403/timeout/解析错误保持原分类，主/兼容 interceptor 行为一致。
- 完成一次手动或自动验证后故意保持 runtime失败，再连续点击刷新/重试，确认不会再次自动跳 WebView；手动“网页验证”仍可重复打开。

本文件覆盖用户要求的全部产品、性能与来源验收；112项有效状态只读`docs/IMPLEMENTATION_STATE.json`。只验证剩余合同，修改生产前须确认新的失败及根因；更新已有文件，不新增ADR/audit、完整子审计或逐轮安装/哈希快照。保持唯一cache、NetLane、窗口/预算及真实退出边界。

## P0：Venera requestId 物理取消闭环

- 验证当前Venera isolated rhttp默认系统DNS等待中的requestId取消及物理退出，不恢复旧native owner。当前VPN不允许ZIC旁路；独立测试包/TestNetwork也未收到DNS包且解析成功对照未完成，仍未验，不以HTTP Future结束替代。Network4/Cookie8已验正文保持。

## P0：后台重入生命周期

- 097真实66页旧21 manifest与21/22 APK已具备，22真实设置保存已验。使用插件声明的rouman5.com后，独立包请求连到::1并被拒绝，Reader未创建；公开DNS为公网地址，设备VPN活跃，解析来源仍未确认。仅待取得真实新manifest后验代际/独立退休，不重复失败请求、不绕过系统DNS；LRU/TTL与composition authority保持。
## P0：纵向性能真机闭环
- 补齐纵向active拖动、拖动→惯性（ballistic）交接的真机视觉连续、输入延迟与最终呈现证据。进入条件为普通Profile/Release与有效physical-display证据；forward future/reverse prefix/scrub及applied-layout合同保持，只有fresh失败证据才重开已验几何。
