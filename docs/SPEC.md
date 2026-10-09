# zic Product and Engineering Specification
本文件是规范，不是实施报告。`MUST` 表示发布合同，`SHOULD` 表示默认要求，`MAY` 表示可选行为。实现和验证状态见 `IMPLEMENTATION_STATUS.md`。
`ARCHITECTURE.md` 描述当前代码如何实现本文件的合同（分层、所有权、机制与数据流），两文件分工不同、不互相复制条款。
## 0. 近期稳定合同：媒体能力、source generation 与下载管理投影
- **Historical carrier trust policy**：**stale presentation continuity MUST 与 fresh transfer recovery 分离**。
  `reuseThenRefresh` 在历史 READY 已真实呈现后 MAY 重置/重跑同一个 physical transfer session 以取得 fresh current exact，
  但 MUST 保留本次已被策略资格化的 exact historical `storageId + generation` 作为只读 presentation-only capability，
  直到 fresh exact 发布、recovery 取消、policy 退出 reuse 或该 storage generation 失效。
  该 capability MUST NOT参与普通 cache lookup/equivalence/canonical/current-exact binding、
  DownloadSession restore 或 network admission；fresh-source quarantine 下只有 presentation reopen/read 可消费它。
  当前 external-static presentation identity 一旦已产生真实 visible frame，
  Reader transfer-progress projection MUST隐藏随后后台 revalidation/convergence 的 queued/receiving/partial 状态；
  这只改变只读 UI projection，MUST NOT暂停、取消、降级或改写底层 transfer。
  manual force reload、semantic presentation failure 或 exact presentation identity 换代 MUST撤销该 satisfied projection。
  current exact/verified cache miss 时，只有相同 `ContentId + sourceRevision` 且为完整 READY 的 historical exact carrier MAY 进入用户选择的 read-routing fallback。
  全局策略 MUST 提供三档：`strictReload`（直接 source）、`reuseThenRefresh`（先复用，实际首帧后再 fresh revalidate current exact）、
  `trustCached`（复用且不自动刷新）；默认 MUST 为 `strictReload`。
  该 fallback MUST NOT 创建 verified equivalence、canonical physical owner 或 current exact durable binding。
  若同一 logical page/revision 的 READY 候选存在多个不同 `(length, checksumAlgorithm, checksum)` signature，
  应用 MUST 通过独立的冲突信任策略决定是否允许最近的完整 historical READY；application-level 默认当前为信任，用户 MAY 全局关闭。
  external plugin MAY 以 tri-state override（inherit/strict/trust）覆盖该默认，
  并通过 source-scoped capability 投影给 Downloads；未归属插件的来源直接使用全局默认。
  该冲突信任只放宽完整 historical READY 的候选资格，MUST NOT 变成 equivalence/content proof，也 MUST NOT 覆盖全局 `strictReload`。
  候选选择 MUST 是稳定的 persistent ordering（当前为最近 `touched_us` 优先）。Reader MUST NOT持有该策略；
  只可在真实 presentation first-frame 后报告 presentation satisfied，由 composition owner 决定是否进行 stale-while-revalidate。
  `reuseThenRefresh` 的后台 revalidation MAY supersede 旧 source/projection generation；
  由 supersession 产生的 typed cancellation 或 `staleEpoch/staleWriter/staleRun` MUST 只退休旧 attempt/consumer projection，
  MUST NOT 把仍有效的 physical `DownloadSession` 发布成 terminal failed。
  新建的空 consumer projection MUST 在进入 live physical fan-out 前对齐 current physical epoch。
  历史 READY 被选中后，在 exact/partial/verified-equivalent authority 都未命中的 local-prepare 阶段 SHOULD 优先直接绑定该 sealed generation 的 exact-range replay capability，
  并仅读取 bounded metadata prefix；
  该 capability MUST NOT 被解释为 verified equivalence、current exact alias 或 canonical proof。
  physical `DownloadSession` MAY 以 body-empty resident authority 直接进入完成态，
  后续 presentation/replay MUST 复用同一 generation-local capability，
  不得回退到按 current exact 重新猜历史 carrier，不得为了可读性复制整份正文进 session artifact，
  也不得为了获得 `promoted` 状态先完整消费 historical body 再重复读取。
  仅当该 resident binding 无法建立时，MAY 回退到既有 ArtifactCache transport response 路径。
- **Venera volatile locator identity**：
  `venera-resource:` MUST remain exact request identity and MUST NOT by itself prove physical-media equivalence.
  Equal source/comic/chapter/pageId/sourceRevision across different carriers is insufficient:
  source output MAY differ at decoded-pixel level.
  A non-exact physical owner therefore requires an already-qualified version-family projection or independent strong media proof;
  historical exact READY/partial MUST NOT be merged solely because the logical page coordinate matches.
  A fresh full source upsert MUST replace stale provider locators in hydrated Home/version authority even when revision/pageCount are unchanged,
  while preserving newer progress. An identical full persisted chapter upsert MUST preserve its published media authority without rebuilding unrelated chapters; revision/count equality alone MUST NOT suppress provider changes.
  Hydrated/version-authority cache MAY retain the full chapter/page payload,
  but MUST NOT become mutable `ReadingProgress` authority:
  Reader re-entry and post-pop projection MUST merge the latest progress through a targeted store-owned lookup that includes already-admitted checkpoints.
  Details MAY project a historical complete page list as a known page-count hint,
  including unique sourceRevision fallback for opaque chapter-token churn,
  but MUST NOT treat that candidate as hydrated command authority unless sourceRevision matches,
  every known positive pageCount matches pages.length,and no Home placeholder remains.
  pageCount==0 means unknown rather than an authoritative empty chapter;
  Reader/download/read-state commands MUST hydrate when those authority checks fail.
  - **Reader transfer progress**：
  Reader MUST 将“已有 physical/durable partial”与“当前 network attempt”保持为两个独立事实，但只在一条共享横向尺度上呈现。
  已有 partial 的可用字节不得因 full-body catch-up / Range restart 从0重读而回退：
  wave MUST覆盖 `0..networkCursor`，若 cursor 小于 partial，
  则 partial 直线只覆盖 `cursor..committedLength`，cursor 追平/超过后不得再画独立 partial。比例 MUST优先使用本地已有总长；
  旧 WebP partial 若未持久化 total，MAY从已恢复的本地 RIFF header读取 declared length 作为 display-only hint，
  真正无法本地得到总长时 MUST NOT用固定短条、虚线或任意宽度伪造比例。
  source response 已给出 full-object length 但 preserved partial 尚未完成 overlap/catch-up 验证时，
  MAY 将该长度作为 current-attempt transient display scale；
  任何显示 hint 均 MUST NOT写入 durable `totalLength`、resume validator、seal/promotion 或 cache authority。
  active queued/opening 且尚无 body cursor 时 MUST显示真实连接活动；
  没有 active unresolved operation 时 MUST NOT因 stale partial projection 永久显示 indeterminate activity。
  - **控制词表与生命周期 owner**：decode waterline producer/consumer MUST 使用共享 typed stage，不得以跨包裸字符串形成调度语义；
  该 stage 只描述 decode refill，不得反馈成 encoded/network admission 或别页 body-flow credit。
  新增/重命名 stage MUST保持这一单向边界，不能重新建立 decode→transport eligibility。
  Reader latest-wins gate、RoleWindow 与 ViewportResolver 的 transition/dominant coverage 边界 MUST 共享同一合同。
  URI 后缀分类 MUST 复用单一容器 evidence；已知 `.jpe/.heic` 等非 WebP 后缀不得作为 unresolved WebP 预建 native output。
  跨 generation 的用户 pause/speed 默认只由 UploadRegistry 持有，具体 UploadSession 负责自身 user pause + viewport freeze；
  Reader session 不得复制第三份播放暂停 authority。Home `dispose()` MUST NOT 代替 owned resource `close()`；
  即使 notifier 已 dispose，后续/并发 close 仍必须 single-flight 地完成 owned library/download/whole-comic teardown。
  `HomeLibrarySession.close()` admission MUST 立即以 `_closing` 拒绝新的 reload/service adoption/stable library mutation/source replacement/version-relation mutation，
  但 MUST NOT 提前置 `_closed`。
  `hydrateEntry`、`hydrateChapterBatch` 与 `ensureCanonicalMediaForEntry` 也 MUST 属于该 admission：
  它们可能在 library read 后更新 version-authority 并追加 canonical-media write/backfill；
  close 后的新 hydration MUST 拒绝，close 前已接纳 hydration MUST 完整完成其 canonical continuation。
  constructor initialization `_ready` 与 close 前已接纳的 public async operations MUST 完整 drain；
  admission owner MUST 覆盖 durable write/readback 后的 projection/canonical publication 与 snapshot scheduling，
  不能只等内部 store Future，也 MUST NOT 串行普通并发 hydration。
  随后才排 version/canonical/snapshot tails、发布 `_closed` 并关闭 owned store。
  whole-App snapshot checkpoint 属于 teardown barrier，MAY 在该 close 链内继续执行。
  `HomeShell` composition teardown MUST 在关闭 external source lifecycle 或 `HomeLibrarySession` 前先 drain current durable-service adoption；
  若该 adoption 已启动 committed source-migration recovery，
  还 MUST drain composition-owned single-flight recovery tail。
  adoption/recovery 完成后 MUST 先 close `HomeReaderChapterComposition`：
  立即封新 Reader preparation admission，并等待所有 close 前已接纳的 hydrate/source refresh/version-authority/response projection preparation 完成；
  该 owner MUST NOT 为此发明独立的 source/network cancellation policy。之后 MUST close `HomeVersionReuseLifecycle`：
  立即封新 version/warmup/Reader-refresh admission，按 exact shared-NetworkLane task key 取消 queued refresh、
  向 active refresh 传播既有 scheduler cancellation，并等待所有 close 前已接纳的 warmup/version/background refresh Future 结束；
  不得由该 lifecycle 创建第二 scheduler 或 `cancelAll()` 共享 lane。
  随后才可依次关闭 external lifecycle、session、source-resource gateway 与 owned cache。
  `HomeLibrarySession.close()` MUST NOT 吸收 source projection/cache/resource/migration continuation ownership。
  App runtime service shell MUST 显式携带 library close ownership：独立打开的 library MAY 由 `_AppServices` close；
  `LazyImportedLibraryStore.ensureDurable()` 返回的 shared SQLite MUST 继续由 bootstrap Lazy 唯一 close，
  service shell MUST NOT close；
  download rebuild/degraded replacement MUST 继承 previous ownership bit，而不是按 non-null store 推断 ownership。
  用户显式 library backup MUST 由当前 library owner 提供一个跨 chapter/progress、
  SavedComic、分类、偏好、已读、source preference 与 migration issue 的一致 semantic snapshot；
  SQLite 实现 MUST 在 snapshot 前 flush 已排队 Reader progress，并在一个无 await 穿插的 read transaction 中完成全部读取。
  Settings/UI MUST NOT 自行逐 section 拼接可跨 revision 的备份；
  Lazy store 的显式 backup MUST 先 single-flight materialize/merge durable library，再从该 owner 读取 snapshot；
  它属于用户主动的 library durability action，不得因 bootstrap memory projection 遮蔽已存在的磁盘数据。
  Android备份 MUST使用平台支持的文档创建/写入路径并保持JSON MIME及文件名，MUST NOT调用file_selector未支持的save-location API；取消 MUST返回空结果且允许后续再次导出。
  备份导出失败 MUST归备份操作诊断，不得伪装成缓存统计读取失败；OS文档操作不得复制library authority或改变snapshot/flush合同。
  长生命周期 Library Diagnostics route MUST NOT 持有 route-open 时的 concrete `ImportedLibraryStore`；
  它 MUST 通过 current-store resolver + library-generation signal 跟随 `HomeLibrarySession` 当前 owner。
  migration issue refresh/copy/ack MUST 在完成时确认同一 generation/store identity；
  若 operation 跨过 library adoption，旧 read 结果不得发布。
  `issueId` 只在单个 store 内有效，acknowledge MUST 用原 issue 的 semantic fields 在当前 store 重新定位 local id，
  MUST NOT 跨 store 重放数值 `issueId`。
  Home 打开的 Local/Remote Comic Details MUST NOT 把 route-open `ChapterDownloadService.changes` 当长期 live authority；
  MUST 监听 `HomeLibrarySession.downloadProjectionChanges`，
  并在每次 signal 后通过 generation-following inspect capability 重读当前 projection。
  若 inspect 跨过新的 projection signal，其结果 MUST 丢弃；current-generation idle MUST 能覆盖旧-generation active。
  direct stream 仅可作为 standalone/test fallback。
  `HomeShell` 对 comic/source preference 与 chapter read-state MUST NOT 直接执行 store `save*` 后手工 `replace*` projection；
  这些 write-through mutation MUST 由 `HomeLibrarySession` 在同一 owner 中完成。
  写入跨 library adoption 时 MUST 等 current service adoption 收口并重试 current store；
  persistence helper 返回的 concrete library identity MUST 在 projection publish 前同步重验。
  批量 comic preference MUST 支持该批 durable writes 全部完成后单次 projection publication。
  同来源漫画别名查询 MUST 按当前 raw comic identity 判定等价，不得因同漫画章节数增长而重复解析同一候选；
  去重 MUST 限于单次查询，下一查询 MUST 读取当前来源 authority，仍保留离线 saved canonical identity 兜底及全部别名偏好合并。
  首页更新筛选 MUST 先检查更新证据，未更新漫画不得触发该筛选的别名偏好查询；更新与入架条件、历史展示语义保持。
  首页同次同步构建的更新与历史列表 MUST 共用一份当前只读漫画库聚合；下一构建 MUST 重读当前 library/source authority，不得跨构建缓存该结果。
  Home snapshot 编码 worker MUST 只接收持久字段投影，不得复制普通章节的完整 pages/prepared manifest 或投影容器的非持久 owner 状态。
  JSON 编码/压缩 MUST 保持异步 worker；compact 普通章节与完整 orphan download metadata、写入串行及完成屏障 MUST 保持。
  durable catalog/preference/read-state DTO 的 JSON 字段转换 MUST 留在该 worker，不得为缩小输入图把整份大目录的转换移回 caller。
  `HomeLibrarySession` 的 chapter、SavedComic 与非 Reader progress write-through MUST 使用同一 generation-stable mutation owner；
  chapter/SavedComic 的 write 与 readback MUST 固定同一 concrete store，
  跨 adoption MUST 整轮重试 current store，并在 publish 前同步重验 persisted store identity。
  Reader page callback 的 checkpoint path MUST 保持非阻塞：
  production bootstrap `LazyImportedLibraryStore` 与 durable SQLite MUST 都实现 `ReaderProgressCheckpointStore`，
  因此 page turn 只 `enqueueProgress`；
  Lazy 在 durable promotion 前 MUST per-chapter latest-wins 保留 checkpoint并异步触发 single-flight promotion，
  `flushProgressCheckpoints` 与 Lazy close MUST 等待 promotion + SQLite checkpoint flush。
  Lazy close MUST 是 joinable single-flight，close admission MUST 立即拒绝新 enqueue/durable mutation，
  但 MUST 允许已接纳 pending checkpoint 的内部 promotion/flush 完成；
  promotion/forwarding 失败 MUST 保留 pending 供显式 flush 重试并传播失败。
  compatibility `unawaited(saveProgress)` 只允许用于不实现 checkpoint capability 的 legacy/test store，
  MUST NOT 让 App/Reader 持平行 pending Future owner，也不得改成等待普通 `persistProgress`。普通翻页仍不得等待 durable I/O；
  Reader route 离开与 app lifecycle flush MAY/SHOULD 形成显式 checkpoint durability barrier，
  barrier 后 Home/详情必须让 durable/current progress outrank route-local 或 hydrated manifest snapshot，
  不能把 manifest hydration cache 当 resume authority。category create/delete MUST 经 `HomeLibrarySession`；
  removeCategory MUST 在同一 concrete current store 内完成删除并读回 categories + ComicPreference cascade proof，
  跨 adoption 整轮重试。
  projection MUST 只合并 category-removal 语义，保留其它当前 preference 字段，并用单次 publication 同步 category 与受影响 preference。
  public `reload`/`ensureReady`/`retry` MUST 与 service adoption 共用 admission ordering：
  reload MUST join admission 时已存在的 adoption 后才 open/read current library；
  adoption MUST join admission 时已存在的 public reload 后才切 service authority。
  实现 MUST 按 admission 先后形成单向等待，不得靠 timeout、第二 generation counter 或 listener 猜测稳定性。
  reload MUST 在最终 publication 前再次比较 Home projection revision；
  若期间已有 session-owned mutation，stale query MUST NOT 覆盖 current entries/saved/version/categories/readStates。
  comic/source preference MAY 保留 reload 新建 defaults，但 same identity MUST 以 current projection 为准；
  active source MUST 从最终 source-preference map 重算。
  synthesized missing source/comic preference MUST 保留 factory baseline timestamp（当前 epoch），
  MUST NOT 写入 `DateTime.now()` 或其它伪造 recency；LWW durability 必须保证任何真实用户 preference 更新压过 stale default。
- **Reader 生命周期播放**：Reader 非 `resumed` 生命周期 MUST 临时暂停 Pipeline playback，同时 MUST 保留用户自己的 pause/speed 设置；
  恢复前台后按用户状态恢复。后台 MUST NOT 继续 Animated WebP decode/upload/present。
- **自适应阅读**：adaptive profile MUST 是多个 Reader 行为共享的类型/证据结果，而不是布局 selector 的一个选项。
  自动分类 MAY 消费漫画元数据、至少两个非封面页面的宽高、
  实测动画证据、来源声明的 typed adaptive reader hint，以及按 `sourceId` 保存的来源级条漫置信；Reader MUST NOT 拥有或持久化来源偏好。
  条漫置信 MUST 使用统一 0–1 语义：0 为强页漫先验、0.5 为中性/自动、1 为强条漫先验。
  非中性值 MUST 经 `ReaderSessionSettings` 只读投影进入分类器并参与 adaptive fingerprint；0.5 MUST 保持无来源先验语义。
  旧单向 `sourceAdaptiveWebtoonWeights=w` 读取兼容 MUST 迁移为 `0.5 + 0.5*w`，不得把历史条漫倾向反转。
  Venera `comic.adaptiveType` 仅允许规范化为 `paged/vertical/animated` typed hint 后跨 plugin boundary；
  Mihon 或其它未声明来源 MUST 保持 unknown，不得由插件名推断。
  漫画自身明确 tag/动画证据 MUST 高于来源先验；足够达到 apply threshold 的用户来源置信 MUST 高于
  provider source adaptive hint 与来源 identity heuristic，使用户可修正来源默认声明。
  页面几何 MUST 使用一次性小样本判定，不得随着 Reader 持续解码页面反复重算布局 profile；实现最多采样 3 张并包含第一页，少于 3 页时使用全部页面，至少需要 2 张才允许几何分类。
  `0.65 < height/width < 1.20` MUST 视为异常/transport-slice 不确定区，自身不得形成页漫几何票；因此类似 `720×700`、`720×500` 的尺寸不能仅凭比例被判成页漫。
  明显普通横页与竖页 MAY 形成页漫证据，极长纵幅 MAY 形成条漫正证据，二者之间必须保留低置信过渡区。
  达到 geometry sample target 后，后续页面尺寸 MUST 不再改变布局 profile；漫画/来源级元数据与来源先验 MUST 独立于已解码页面数。
  地域/语言相关标签 MAY 作为弱证据，但不得仅凭“韩国/韓國”等地域词硬切阅读模式。
  来源先验或 typed source metadata 变化 MUST 使与旧证据绑定的持久 adaptive profile 失效；
  实现不得为插件、来源页和 Reader 各建一份互相覆盖的设置 authority。
  全局 `adaptiveReaderEnabled` 与漫画级 `comicAdaptiveEnabled` MUST 独立于漫画手动 override master；
  adaptive 生效条件为二者同时开启。旧 `enabled=false && adaptiveEnabled=false` MUST 继续表示
  “没有开启手动漫画设置，但该漫画停用自适应”，不得强行迁移为启用的方向 override。
  漫画级手动阅读方向 MUST 只有 `跟随 / LTR / RTL / 纵向` 一个互斥轴；显式方向 MUST 只覆盖方向，
  MUST NOT 阻止 adaptive profile 更新或阻止手势、未来翻译等其它消费者读取 profile。
  当前长按放大 MUST 按“漫画显式覆盖 > 高置信 adaptive profile > 模式默认”解析：
  vertical/webtoon profile 默认关闭，paged/animated profile 默认开启；无 profile 时纵向默认关闭、分页使用 global baseline。
  漫画手动 override master MUST 只 gate 方向、纵向拼接、长按放大、阅读顺序等手动覆盖，不得 gate `comicAdaptiveEnabled`；
  “使用自适应设置”入口在手动 override 开启后仍 MUST 可见。清除手动覆盖 MUST NOT 重置漫画级 adaptive 开关或已持久化 adaptive profile。
  全局分页方向 MUST 独立提供 `LTR / RTL / 跟随来源` 三态且默认 LTR；方向解析优先级为漫画显式方向 > 高置信 adaptive 方向 > 全局分页方向。
  纵向拼接、长按放大以及其它少量离散枚举型 Reader 设置 SHOULD 用直接互斥胶囊/segment 展示，
  不应为三个以内的简单选择保留下拉框；数值范围仍可使用 slider。
  adaptive profile MAY 继续增加翻译源语言、自动翻译等 typed 建议，但不得把翻译执行 ownership 或
  Pipeline 的 NetLane/download/decode/prefetch ownership 搬进 Reader。
- **动画能力**：`animatedHint`、后缀和来源声明 MUST NOT 直接显示播放专属控件。媒体能力 unknown 时控件 MUST 隐藏；
  两个实际帧可形成 animated 正证据，static 只在完整/codec 静态证据成立后确认。
  纵向 measured geometry 改变页面真实 extent 后，Reader MUST 在 layout 生效后无手势重发真实 visible coverage；
  Pipeline MUST 以独立于 PageRole 的 typed viewport-visible fact 驱动 presentation。
  fallback first-frame admission MUST保持有界：
  通用Coordinator缺省可只串行1个speculative external grant，Reader profile MAY显式允许最多3个offscreen external-static first-frame pending；
  真实可见/current/transition页 MUST NOT计入该speculative cap，也不得因另一grant尚未回报Flutter first-frame而保持黑屏；
  离开 viewport 的未完成 grant MUST 被撤销。纵向active scroll对hidden native/provisional static texture的defer MUST继续保留；
  但当前generation metadata prefix若由共享encoded-image sniffer精确证明为JPEG/PNG/BMP/TIFF/ICO/AVIF/HEIF等external static，
  则该页 MUST可在既有3/7 one-frame envelope内继续staged presentation，使首帧可在进入viewport前完成。
  offscreen grant MAY由composition注入的detached presentation executor消费既有generation-scoped file/bytes capability并写入**同一个Flutter ImageCache**；
  该executor MUST NOT选页、开网络、创建隐藏Reader/Page widget、拥有retry/cache authority或创建第二raster cache，
  且只能向Coordinator回报同一exact grant一次，后续挂载页 MUST复用同一generation/cache identity。
  `ContentKind.fallback`、默认`animatedHint=false`或opaque URI单独均不得作为该证明，HTML/error fallback MUST保持unclassified。
  - **source generation**：
  一次 Venera semantic recovery generation 内 replacement 次数 MUST 保持有界，普通失败恢复 MUST NOT 重置。
  用户显式 retry 章节时，优先只刷新上一轮真正以 `ErrorCode.source` 终止的 source-owned locator；
  若任务来自旧进程/旧版本且 terminal locator 证据未持久化，本次显式 Retry MAY 在首次重新遇到明确 `ErrorCode.source` terminal locator 后，
  仅对该刚触达 locator 开启一次 fresh generation 并在同一用户命令内继续一次，MUST NOT 刷新未触达页、MUST NOT 对同一 locator 无限 fresh。
  fresh refresh MUST 清除 host request-plan 与 runtime retained config/resolution 后重新执行初始 source image config。
  - **下载管理投影**：自动缓存存在性 MUST 以 durable physical authority 为准；
  known chapter MAY 由 canonical physical artifact/partial 直接形成管理投影，不要求 exact READY binding。
  durable mutation MUST 通过轻量 invalidation 驱动打开中的 Download Manager 合并刷新；
  显式章节下载期间只累计 dirty，全部 run 结束后最多补发一次 management refresh。**Reader stale-carrier recovery boundary**：
  presentation/Reader 层 MUST 保持 source-neutral，只能上传 typed/opaque failure 到 App composition，
  MUST NOT 直接调用 Venera `loadEp`、source runtime 或建立第二 retry owner。
  只有 source-owned semantic recovery 已明确 unavailable 且 accepted replacement plan 为0时，
  App MAY 由当前可见页触发一次 fresh chapter/page authority refresh；旧 Reader 在 refresh 期间 MUST 保持挂载。
  触发资格仍是单页、每 route 有界，但 source generation 是 chapter-scoped carrier authority：fresh list 必须按旧 logical page identity
  对全部既有页做一一匹配，并在同一 `sourceRevision` 下原子替换这批 transport carriers；不得只 splice 失败页后把两个 generation 的 locator
  持久化在同一 chapter。任一旧显式 page identity 无法在 fresh list 中找到、映射重复、sourceRevision/identity 漂移时 MUST fail closed；
  fresh list 的失败页 authority 无变化 MUST 回落 existing exact-page retry，而不是把 metadata refresh 视为媒体恢复成功。
  carrier batch MUST 保留旧 chapter 的结构/page order，fresh list 新增但旧 revision 未声明的页不得借媒体恢复偷偷进入 chapter；
  因此该操作仍是同一 logical chapter 的 carrier-generation rebind，而不是整章内容迁移。
  Reader 首帧后的 metadata/version refresh MAY 获取 fresh source chapter snapshot 用于版本/复用判断，
  但 MUST NOT 因该后台观察替换或持久化 `pages[]` transport carrier；
  只有上述 terminal source-generation recovery、显式 source refresh / legacy-locator migration 等完整 chapter-authority 命令可改 carrier。
  `PipelineReaderSession` retention 的 coarse key 只能筛候选；
  恢复 retained session 前 MUST 再比较完整 `ChapterManifest` session input，carrier/metadata 任一变化都必须创建 fresh session。
  - **Venera source-read transient recovery**：
  只读 source metadata invocation 若且仅若本次实际发生网络调用并因 JSON `SyntaxError` 失败，
  MAY 在 runtime/adapter 边界继承同一 `TaskControl` 做一次 fresh replay；
  fresh MUST bypass runtime HTTP cache，第二次失败 MUST 终止，Reader/UI MUST NOT 追加 retry owner。
  `Cache-Control: no-store` MUST 撤销同 URL 的旧 runtime cache authority。
  - **Venera request-scoped async cancellation**：每个 `ZicNative.requestAsync` JS waiter MUST 绑定当前 `requestId`。
  取消该 request 时 MUST 同时取消 native resolver I/O / delay waiter 并移除、
  reject其JS async bridge waiter，使正在等待 `Network.*` 的 source invocation 能立即 unwind；迟到bridge response MUST被忽略。
  JS `finished(requestId)`与已接纳native bridge work退出 MUST分别等待，两者齐备才可转发result并交出唯一stateful invocation permit。
  native call MUST在原executor提交前登记、物理finally退出后退休；取消标记 MUST保留到双退出边界，迟到result/token不得复活。MUST NOT以提前释放permit实现抢占。
  Native runtime关闭 MUST先封新调用，等待已接纳同步bridge、executor work与isolated图片primitive物理退出，再回收输入/图片并发送pending关闭结果。
  重复driver关闭 MUST join同一`closeWhenDrained`完成边界；host MUST保留driver登记及已接纳activation到真实退出，晚到driver MUST退休后才完成host关闭。
  Service MUST保留resolver所需FlutterEngine/Main回调到native退出，并drain原IPC读取、回包与cleanup后才清packet store；MUST NOT在Main阻塞等待或以超时/请求取消代替物理完成。
  Exclusive download-storage root switch MUST first dispose only idle retained Reader sessions,
  then inspect transfer consumers;an active mounted Reader MUST remain a blocking consumer.
  - **Android cached-presentation open boundary**：
  已经由 durable artifact owner 证明 READY 的 App-private Direct/SAF static presentation，
  其只读 descriptor open MUST 与 SAF tree/path/namespace mutation 分离。
  Direct `presentationOpenDirect`、SAF `presentationOpenSaf`、
  read-only SAF open/prewarm MUST 进入同一个 bounded local read-open execution domain；
  单线程 path executor MUST 只承担 tree/path resolution 与 namespace mutation。
  该平台并发仅避免无关 path FIFO 阻塞，MUST NOT创建第二 cache/read scheduler、
  跳过 persistent locator/existence/exact-length proof或改变 network/download admission。
## 1. 产品范围
zic MUST 支持 Android 上的本地/远程漫画、LTR/RTL/纵向阅读、静态图片、Animated WebP、
partial/resume/offline artifact、漫画源浏览与受控插件扩展，以及本地 Debug Trace 导出。

项目不承诺 DRM 绕过、通用视频播放、社交功能或模型直接操作底层资源生命周期。

阅读引擎的几何、输出与资源调度合同见第 2、3 章；各合同的实现机制（分层、所有权与数据流）见 `ARCHITECTURE.md`。
### 1.1 首页冷启动
- 核心服务 MUST 在 bootstrap Home 首帧后自动打开，不得以进入 Reader 作为启动触发。
  `HomeLibrarySession.adoptServices()` 的完成边界是持久权威、运行时绑定替换和旧 owner 安全退役；
  Home 全量投影仍由 `ready`/`services-handoff-complete` 单独收口。Reader MUST 等待能力绑定，但 MUST NOT 因此等待无关的 Home 全库重载；
  绑定失败必须向加载路由报告，不得静默继续使用已退役 owner。
- bootstrap 与 durable service 之间 MUST 通过稳定 handoff 原地切换 `HomeLibrarySession` 的服务；
  不得因服务到达更换 `MaterialApp`/Home key 或销毁重建首页导航状态。
  快照已证明 revision 一致时 handoff MUST 保持现有更新漫画/阅读历史投影，不得重复发布同一 projection。
  `HomeLibrarySession` MUST 在构造/adopt 时把显式 `downloadComposition` 与 chapter-service 提供的 transfer capability 正规化成唯一当前 composition capability；
  该 explicit-first/fallback 规则 MUST 只有 session 的单一 resolver，
  Home bootstrap/service handoff/cache binding MUST 复用它而不得自行 `is/as ChapterDownloadTransferRuntimeProvider`；
  Reader/App consumer MUST 从 session 读取该 capability，
  MUST NOT 在 UI route 对 `ChapterDownloadService` 做 `PartialDownloadStore`/transfer-provider 下转型。
  Session close MUST 在 `_closed` publication 与 owned library close 之前排空已 admission snapshot writes；
  Widget notifier disposal MUST 后于 async owner close。

- Home MUST 在本地库的 cover-bearing primary 数据可用后先呈现首页；
  native media prewarm、持久整本队列 restore、外部插件 activation 和 enrichment 不得成为首封面请求的硬门槛。
- 启动 build MUST 不等待 durable services。
  入口 MUST 直接挂载不依赖 durable services 的 memory-backed Home，不得创建自定义 Flutter bootstrap surface；
  durable service open MUST 在首个 Home frame 之后立即异步启动，且不得决定 Home 是否可见。
- 空安装 MAY 在没有用户持久动作时保持 memory-backed Home 且不创建 core SQLite/WAL；
  首次显式章节下载或整本入队 MUST 在冲突探测、placement claim 和任何下载/队列写入前等待同一个 runtime-owned durable handoff，
  并原地采用 library、chapter composition、artifact cache 与 whole-comic queue。
  强制打开或 adoption 失败 MUST 终止该动作，不得让内存下载服务发布伪持久完成状态。
- 外观 MUST 读取并持久化 `ThemeMode`；AMOLED 开关启用时，且当前有效主题为深色，`darkTheme` 的 surface/scaffold/canvas 背景 MUST 使用纯黑。
  首帧加载背景 MUST 跟随有效主题，不得为启动阶段强制使用浅色。
- 首页根路由的系统返回 MUST 先显示“再按一次返回到后台”确认提示，并在确认窗口（当前为 2 秒）内再次返回才把当前 Android task 移到后台；窗口过期后 MUST 重新要求确认。
  该确认 MUST 只拦截根路由自身的返回，MUST NOT 改变其他路由（Reader、详情、对话框）或漫画源页内部返回手势的既有语义。
  第二次根返回 MUST NOT等待partial checkpoint、service/runtime close、
  偏好flush或其它durable I/O，MUST NOT主动detach/destroy FlutterEngine 或 finish task；
  Android宿主 SHOULD使用`moveTaskToBack(true)`保留当前Activity/Dart owners，不支持该能力时才 MAY 回退平台普通pop。
  真正service/runtime shutdown仍由各owner自己的teardown边界完成，不能由用户返回导航动作冒充。
- Durable service open 完成后 MUST 主动提交内存 Home 到 durable projection；
  该提交不得只注册等待下一帧的回调而不安排 frame，否则用户手势不得成为加载更新漫画和阅读历史的隐式触发条件。
  已有可信 `HomeProjectionSnapshot.chapterDownloads` 且 library revision 一致时，该快照 MUST 作为 handoff 的可用下载状态；
  启动自动校准 MUST 只 revalidate 快照中已有的 manual/auto-cache identities，
  MUST NOT 顺带执行全部 library entries 的 orphan/download-management scan。
  只有快照缺失、损坏、无 revision 或无法证明一致时 MAY 做一次 full recovery reconcile；
  完整 orphan/management projection 属于 Download Manager/显式刷新。
  启动校准若 persisted download summaries/orphans 未变化 MUST NOT 重写 Home snapshot。
  durable exact READY promotion 或 canonical physical partial checkpoint 在持久提交成功且 mutation generation 仍有效后 MUST 发布 management-projection invalidation；
  该信号只表示 durable inventory 可能变化，consumer MUST 重新读取 authority，stale/rollback mutation MUST NOT 发布该信号。
- 首帧前只允许建立轻量 startup/trace channel；
  native decode、`media_core` texture、rhttp 和 feature bridge MUST 在实际 Reader/source/platform capability 使用前保持未初始化或未挂载，
  首次使用只能由对应 capability 自己按需挂载。
- 用户 MAY 在 bootstrap Home 可见时立即进入 Reader，加载路由 MUST 可先显示；
  App composition MUST 在投影 Reader 章节能力和构造 Pipeline 前等待持久化服务就绪及 Home 接管，不得捕获随后退役的 bootstrap cache/download owner。
  失败 MUST 由加载路由报告，不得静默回退旧服务；此生命周期等待 MUST NOT 演变为 Reader/UI 网络准入门控，也不得等待无关插件启动。
  Reader 打开章节时 MAY 提前启动 native decode worker/texture capability prewarm，
  但该 Future MUST NOT 成为章节 materialization、DeferredReaderRoute ready 或 source-plan 的硬门槛；
  真实 capability 使用路径必须能够独立 join/retry。
  首帧/output readiness MUST NOT改变 NetLane source bucket limit，也 MUST NOT预先建立 composition local-read pressure；
  local bucket 保持 profile 稳定值，local-read pressure只来自真实 foreground read/pending read 或明确 operation-level owner。
- Android `FlutterEngine` MUST 关闭 embedding 的自动 `GeneratedPluginRegistrant` 注册；
  仅覆盖 `configureFlutterEngine` 不足以满足该边界，因为隐式 engine 会在该回调之前注册插件。
  feature bridge 只能在对应 capability 通过 startup channel 显式挂载。
- `LocalMediaBridge` 的 Android `pickImageDirectory`、
  `scanImageDirectory`、`openDocument` 与 `readDocument` MUST 在调用 `dev.zic/local_media` 前通过 startup channel single-flight attach `local_media_bridge`；
  这样持久记录直接恢复到 Reader 时不得依赖曾经执行过的文件夹选择流程。
- Android 应用存储根目录 MUST 优先随 Dart entrypoint args 同步注入，避免冷启动首次 MethodChannel 往返；
  旧宿主才由轻量 startup channel 返回，不能为了首个 `path_provider` 查询提前挂载 JNI。
  Home/runtime composition MUST 直接挂载到 Flutter root，不得通过自定义 bootstrap surface 或 deferred loading unit 延后首个可见 raster。
  Android 上“首帧已可见”的权威边界 MUST 是平台 `onFlutterUiDisplayed`（或等价的宿主可见性证据），不得把 Dart post-frame/raster 假设当成替代；
  只有跨过该边界后才 MAY 打开 durable/native/plugin capability。UI isolate 仍是唯一的 Flutter presentation/composition owner。
- 新安装且不存在 imported-library、offline-cache 或 whole-comic queue 状态时，Home MUST不打开 SQLite 或创建 WAL/schema；
  `LazyImportedLibraryStore` MUST 以内存投影服务，并在首次明确持久化写入时先将该投影迁移到 SQLite，再转发写入。
  已有 durable state 的服务只能在 Home 可见窗口之后打开。SQLite 句柄 MUST NOT 跨 isolate 传递。
- 已有 durable state 时，Home MAY 先读取 `HomeProjectionSnapshotStore` 的上一次成功投影，以 stale-while-revalidate 方式显示更新漫画和阅读历史；
  bootstrap/memory-backed Home MUST NOT 将空投影写回快照。SQLite MUST 继续是唯一事实源。
  快照 SHOULD 保存 SQLite Home projection revision；修订号一致时 MUST 直接复用 Home primary，并只对快照内已有的持久下载identity做有界校准；
  只有修订号变化或无法证明一致时才扫描事实源。真正App owner/service shutdown MAY在相关Reader progress owner已经静止后flush最终progress，
  并以最新SQLite revision checkpoint Home snapshot；该teardown优化不得绑定根返回/后台化手势，也不得被描述为任务界面强杀时必然执行。
  compact snapshot entries只保存Home元数据、pageCount、cover locator与progress，不复制完整page locator；
  旧/不兼容快照读取成功后按当前格式自动原子重写。
  compact entry在Reader、实际下载/删除命令或版本迁移等会消费正文locator的路径前 MUST 通过authoritative library hydrate完整pages；
  `zic-home-snapshot-page:*` placeholder MUST仅作为Home/bootstrap projection，
  MUST NOT进入VersionPageAuthority/canonical media authority、
  Reader/download manifest、DownloadId或source resolver；
  hydrate后仍为placeholder的remote chapter MUST source-refresh，无法获得真实locator时 MUST在媒体demand建立前fail closed；
  同源版本准备 MUST先hydrate已有章节再判断locator是否需来源刷新；有效完整manifest MUST原样复用，hydrate后的取消 MUST阻止后续source load/upsert，旧locator的兼容刷新 MUST保留。
  只读下载状态批量投影若底层显式支持compact placeholder/pageCount，则 SHOULD 直接消费compact entry，MUST NOT仅为状态检查逐章hydrate完整locator。
  快照缺失、损坏、版本不兼容或读取失败 MUST 静默回退SQLite，不能阻塞Home或覆盖SQLite数据。
- 漫画源迁移跨 artifact cache、target library metadata 与旧 source cleanup 时 MUST 使用 App-private library DB 中的 durable source-migration journal，
  而不得假装文件系统与两个 SQLite owner 可全局原子提交。
  phase MUST 单调为 `prepared -> artifactsReady -> metadataCommitted -> cleanupPending -> done`：
  前两阶段失败 MAY 在用户重新确认同一 target fingerprint 后幂等重试；
  一旦 `metadataCommitted`，target 已成为 authority，后续恢复 MUST NOT 回滚或重新解释 target，只能继续幂等 source cleanup。
  进入 cleanup 前 MUST 先持久化 `cleanupPending`；
  cleanup 失败 MUST 保留 debt 供 durable handoff 自动恢复，且该 journal 控制状态 MUST NOT 推进 Home projection revision。
- 快照序列化结果超过 64 KiB 时 SHOULD 使用 gzip，读取 MUST 同时兼容明文与 gzip；旧 v1 或大型明文快照读取成功后 MUST 自动原子重写为 v2 compact gzip。
- Whole-comic queue MUST 保持为独立队列状态文件，不得复制 Home entries 或章节正文；
  恢复 SHOULD 通过章节下载索引的 `inspectMany()` 批量投影，并在 Home primary 可见后后台完成，queue `ready` 不得成为更新漫画或阅读历史首显的硬门槛。
- 空的或从未产生阅读记录的 imported library 打开 MUST NOT 创建 Reader progress writer或第二个 SQLite/WAL 连接；
  该 writer 只能在首次真正写入 `ReadingProgress` 时懒启动，且不能反向成为 Home 冷启动的硬门槛。
- Home 启动期缺失的来源/漫画默认偏好 MUST 先以内存投影提供给首个 Home；不得为建立这些默认值在 UI isolate 同步执行 SQLite 写入。
  只有用户明确修改偏好时才 MUST 持久化该偏好，之后的 reload MUST 继续尊重已存储值。
- 首次安装缺失的 `app_preferences.json` MUST 先使用内存默认偏好；启动阶段不得为写出完整默认文档执行 flush/rename。用户首次修改任一应用偏好时才创建并持久化该文档。
  `AppPreferencesController` MAY继续用总通知承载持久化及叶级消费者更新，
  但 `MaterialApp`/全局 Theme shell MUST只订阅实际影响 `ThemeData/themeMode` 的窄projection；
  comic Reader settings、adaptive profile、网络/下载/搜索等非主题偏好变化 MUST NOT 因此重建被Reader覆盖的Home route。
  `themeMode`与AMOLED主题变化仍 MUST立即使theme shell失效并重建。
- 外部来源可以在首帧之后 ready；封面 presentation MUST 使用稳定 canonical artwork identity。
  cache miss 在等待中的外部 source 首次发布前 MUST 保持同一个资源请求 pending，不能先以 source-unavailable 失败；
  source readiness 完成后仍不可用、transport 或 decode 失败时 MUST 保持稳定占位，
  不得由定时器、App resume、first-frame watchdog、provider eviction 或 loader closure 变化自动重启请求；
  Home/历史和书架画廊/列表封面 MUST 在卡片局部消费既有来源投影信号并重读 current source availability。
  先前 source-failed 的封面在 unavailable→available 时 MAY 重新提交 gateway 请求；健康和 pending 封面 MUST 保留原 Future/canonical State，
  来源发布 MUST NOT 为此重建整个 Home library projection 或建立独立 retry/network 状态。
  Home/书架封面 State MUST 独立于当前 raw comic/resume chapter 的点击 key；
  alias、章节或 enrichment 更新 MUST 保留同一 canonical artwork，点击命令与交互 key MUST 仍采用当前 raw 身份。
  来源列表 Sliver 重新挂载 MUST NOT重新发起同一稳定 canonical card 已失败的来源请求。
  来源 card 的内部交互祖先 key MUST 与 Sliver 使用相同的来源 canonical identity；raw locator 更新不得销毁现有封面 State。
  `sourceComicCardKey` MUST 使用 canonical identity，点击/来源请求 MUST 继续使用当前 raw locator，不能用 presentation key 改写请求身份。
  同一普通来源页的 canonical alias MUST 归并为源顺序中的首条 summary；cached/refreshed投影比较 MUST 一致，且不得逐帧重复归并。
  归并 MUST 保留来源 nextOffset；无显式坐标的后页步长 MUST 使用原始条目数，不得使用显示卡片数。
  上一页 MUST 使用已接纳的实际访问坐标，序号按访问路径展示；不得用请求limit推算反向坐标。
  来源view恢复 MUST 保留请求分区内的页码/路径且缓存恢复同样归并；section/filter分区改变 MUST 重置为0。
  访问路径 MUST 限于UI导航意图，随query/filter/section/page0重置；不得成为source/runtime/cache/transport cursor authority。
  来源列表只有显式来源刷新、资源 revision 或稳定 identity变化才能重新加载。
- Venera JavaScript `Image` compatibility MUST match the reference runtime rather than Android drawing defaults.
  `Image.fillImageRangeAt(x,y,image,srcX,srcY,width,height)` MUST accept `width==0` or `height==0` as a no-op because source transforms may intentionally emit empty slices;
  negative size or any non-empty source/target overrun MUST fail.
  Host MUST validate both source and target ranges before Canvas draw and MUST NOT clamp a real overrun into a silently corrupted image.
- Home 启动 MUST NOT 枚举 Android 上全部已安装包来发现 Mihon 扩展；设备扩展发现只能在来源管理页面的显式操作路径执行。
  外部插件 manifest 恢复和已安装 runtime activation MAY 在首帧后的 capability handoff 中后台执行，但不得成为首封面硬门槛；
  该 handoff MUST 独立于 imported-library/download/queue durable-state 判定，
  只有 external-plugin manifest 的安装仍 MUST 能进入 Mihon/Venera 管理页且不得为此创建空 core SQLite。
  首次插件宿主打开失败不得把 settled null/error single-flight 永久复用于后续显式操作；显式来源管理 MUST 能重试。
  Home 封面等待 source readiness 时 MUST 保持 pending。显式来源管理操作仍可触发设备扩展发现与刷新；
  逐插件 source change 在 projection single-flight 退出边界到达时 MUST 被后继 refresh 消费，不得丢失。
  `HomeExternalSourceLifecycle.close()` MUST 同步 fence 新 refresh/adoption 且并发 close join 同一完成边界；
  已经进入 Home projection callback 的 refresh MUST drain 后 close 才返回，
  但 optional controller loader/ready 尚未进入 projection callback 时 MUST NOT 成为 teardown barrier。
  HomeShell teardown MUST await lifecycle close 后才开始 `HomeLibrarySession.close()`，
  禁止 external refresh 与 session closing 并发。
  持续打开的 Source Management route MUST 跟随 current external controller/source projection：
  同一 controller 的后台 activation/source change 以及 controller identity handoff 都 MUST 触发窄 source-projection signal，
  UI 随后通过 resolver 重读 current controller/activeSources；
  MUST NOT 直接依赖整个 Home service handoff，也不得只保留 route-open source/controller 快照。
  App runtime 的 external plugin controller MUST 独立于 core service generation：
  bootstrap/deferred→durable adoption、download-service rebuild 与 degraded fallback MUST 转移同一 controller ownership，
  而不是创建/丢弃/复制第二个 controller；
  已存在 controller MUST 从 predecessor 移除并由 successor 唯一关闭，尚未启动的 stale loader MUST 委托 successor；
  已经启动的 predecessor open MUST 自己完成并把 controller 沿 successor 转交，
  MUST NOT 从该 predecessor flight 内再次调用 successor ensure（successor ready 已继承 predecessor 时会形成等待环）；
  in-flight ensure MUST 返回 successor current controller，successor teardown MUST 等待 inherited ready tail。
  core adoption MUST NOT 等 fixed timeout 等待 optional plugin host；
  late completion MUST 重新发布 current controller 到 `HomeServiceHandoff`。
  install/edit inspection 的 pending payload MUST 由 `ExternalPluginController` transient owner 管理：
  每一 pending generation MUST 有 controller-private claim；
  discard/approve MUST 同时匹配 current claim 与 payload path，
  旧 preview 或手工构造的 unclaimed preview MUST NOT claim 新一代/任意 payload，
  same-plugin inspect generation MUST 在请求发起时建立；
  后发起者 MUST supersede 前代，早代慢下载/慢 inspection 晚完成时 MUST 只清理自身文件且 MUST NOT 重新发布 pending。
  producer 失败也 MUST NOT remove 另一 generation 的 pending entry。
  normal close MUST best-effort 删除本进程仍 pending 的 payload，
  且 close/inspect 并发时 inspect MUST 在 final rename 与 metadata inspection 后重验 open 状态；
  已 approve/manifest-owned payload MUST NOT 被该 cleanup 删除。
  approve/retry/remove 与后台 source-identity activation MUST 共享 controller durable mutation gate：
  close MUST 是 joinable 的单一完成边界（并发调用 MUST 共享同一个 close Future），
  底层 `ExternalPluginRuntimeRegistry.close()` 同样 MUST 共享单一 close Future；
  同一 plugin 的 deactivate MUST single-flight 并形成 destructive admission fence：
  deactivation 一旦接纳，后续同 plugin `activate/replace` MUST 在读取 existing session 或启动 replacement candidate 前拒绝；
  若 activation/replace 先接纳，deactivate MUST 等其完成并随后关闭 current session。
  该 fence MUST 仅按 pluginId 生效，不得串行化其它 plugin；registry close MUST 先 drain 已接纳 deactivate、再快照/关闭剩余 sessions，
  MUST NOT 假设 `ExternalComicPluginSession.close()` 幂等或 joinable；
  controller close MUST 先封新 admission、立即启动 registry shutdown，
  再等待此前已接纳 mutation 与 manifest write tail 排空，之后才能完成 pending cleanup/sourceChanges close；
  controller mutation gate MUST 以 pluginId 为 key 串行同 plugin 的 approve/retry/remove/save、
  后台 activation 与 Mihon runtime restart；
  后台 `_activateRecord` 在取得 plugin key 后 MUST 重验捕获 record 仍与 current `_installed[pluginId]` identity 相同，
  已被 remove/replace 的 stale startup/source-demand snapshot MUST 直接丢弃且 MUST NOT 写 activation failure/source projection；
  同时 MUST 保持不同 plugin mutation 并行；repository load、device scan、inspect 等 transient work MUST NOT 进入该 gate。
  registry MUST 只负责 runtime session/deactivation 次序，MUST NOT 被迫推断它不可见的 physical payload identity；
  runtime host 对 admitted installed record 的 cached/fallback inspection MUST 只读该 `InstalledExternalPlugin.payloadPath`，
  inspection path MUST 与 record path 相等，MUST NOT 从 mutable pending map 重新解析运行时 payload。
  crash-recovery MUST NOT 仅以“current manifest 未引用”删除 payload，因为 manifest recovery generations 可能仍引用旧文件；
  必须有独立 durable pending proof 才能自动回收。
  nested repository/Venera editor MAY 持有导航时 current concrete controller，不应额外获得 service-generation owner。
  外部 source availability lifecycle 与 resolver-visible source projection MUST 是独立 composition owner：
  Widget State MUST NOT 自己持有 plugin source subscription/refresh queue、
  cached source list 或 canonical-id persistence；source projection MUST 显式接收/追踪当前 external source identities，
  decoration MAY 仅在底层 producer、response cache 和创建时 producer transport generation 均相同的情况下复用；真实 generation mutation、source replacement 或 cache handoff MUST使用新绑定，实时 transport identity MUST继续委托producer。
  MUST NOT 通过 Mihon/Venera 等 sourceId 前缀反推 external ownership；
  library、chapter download、download composition 与 whole-comic queue 的当前 authority MUST 只由 `HomeLibrarySession` 持有，
  Widget State 不得保存平行 mutable service fields。
  cache generation MUST 以一个绑定同时携带 Reader artifact cache、`ResourceCacheCoordinator` 与 close ownership。
  durable service adoption single-flight、该 cache binding 的 generation commit、source-resource rebind 与 source projection commit
  MUST 由独立于 Widget State 的 `HomeServiceAdoptionCoordinator`（或等价非 presentation owner）顺序化；
  `HomeShell` MUST NOT 自己保存 adoption Future/cache-generation mutable authority，只能触发、等待并在 teardown 时 drain 该 owner。
  Home 的进程内 route admission（Reader 覆盖态、Download Manager 重复打开抑制、comic identity 重入锁）MUST 由独立纯状态 owner 持有；
  该 owner MUST NOT 获取 `BuildContext`/Navigator、service/cache/source/download/version authority，真正 route 构造与 UI refresh 仍由 `HomeShell` presentation composition 负责。
  durable service handoff MUST 把同一 `downloadComposition` 显式交给 session，
  先完成或确认 session adoption，再提交新的 resolver/cache projection；session 未采用候选时 MUST 回收 Home-owned candidate cache，
  session 已切换 authority 后不得因后续 reconcile 错误让 Home 回退旧 generation。
  same-service 的 source/cache projection 变化仍 MUST 发布到 session；
  handoff single-flight 完成后 MUST 重检最新 published generation 并继续 drain，不能丢失飞行期间发布的 service replacement。
  Home teardown MUST 先 fence 新 service adoption，再等待 close 前已经接纳的 adoption 完成；不得以 Widget `mounted` 状态取消已接纳的 owner 工作。
  冷启动进入 Reader 或加载非 local-folder 章节前，MUST 等待对应外部来源就绪，
  不得在插件发布前构造空 responseLoaders 进入 Reader 或回退为本地文件/openLocalMediaResponse 读取。
  已持久化漫画已有本地详情投影时，详情 route MUST 先用该投影完成首帧，deferred external source activation MUST 从下一次 post-frame 后异步开始，
  不能成为 Navigator push/详情首帧的前置条件；source 后续发布后 MUST 在同一详情 State 上原地补充 source-dependent capability，不能要求退出重进。
  同一详情 route 用于比较 `route-push`、`details-first-frame`、
  `deferred-source-ready` 的诊断时间戳 MUST 来自同一个 composition monotonic clock；
  组件本地 fallback clock MAY 用于独立事件，但 MUST NOT 与 composition epoch 混合后推导跨组件延迟。
  未持久化章节每次 materialize/retry MUST 通过 live source resolver 重新取当前 source。
  source尚在激活时，未持久化章节MUST等待既有route activation Future后重新解析；MUST NOT提前判为不可用或新增轮询/retry。已有chapter记录MUST不等待该Future；详情关闭后MUST不继续materialize。
  Home 的 chapter/whole-comic service mutation MUST 经独立 download-command composition owner 执行；
  该 owner MUST 从 `HomeLibrarySession` 动态读取当前 service generation，不得缓存 handoff 前的 chapter/queue service。
  Network/Download Settings MUST NOT 持有 concrete `WholeComicDownloadQueue`；
  policy 展示 MUST 读取 session-owned whole-comic snapshot projection 并监听同一 download projection invalidation，
  policy mutation MUST 调用 `HomeDownloadCommands.updateWholeComicPolicy`，
  使已打开 route 在 service adoption 后仍跟随新 generation。
  任何实际删除 chapter 正文/下载文件的 delete MUST 在 service mutation 前完成 durable core-service handoff；
  仅删除 library metadata 的操作 MUST NOT 因此被迫打开 durable download services。
  UI/`part` extension MAY 读取 changes/snapshot 并呈现冲突对话框或完成状态，
  但 MUST NOT 直接重新实现 download/retry/cancel/delete/probe/placement/enqueue/pause/resume sequencing。
  长生命周期 Settings route MUST NOT 缓存 handoff 前的 whole-comic queue、
  resource-cache coordinator、storage root 或 chapter-download relay；
  下载策略与 Data Settings MUST 通过 generation-following binding 读取当前 projection/capability。
  cache usage inspect MUST NOT 仅为展示而强制创建空 durable core；
  用户显式 clear/trim MUST 先完成 core-service handoff/adoption，再在一次 mutation 内使用同一 current coordinator。
  chapter-download relay availability 改变时 handoff MUST 发布 change signal，
  使已打开的 Data Settings 不依赖退出重进即可刷新 capability。source/version migration 在用户确认前 MUST 仅执行目标加载、身份比较与风险展示；
  确认后的 prepared fingerprint/journal、exact target chapter preparation、
  verified artifact reuse、SavedComic/偏好/进度/已读状态 commit 与 committed cleanup/recovery MUST 由独立 `HomeSourceMigrationTransaction` 持有；
  但 ComicPreference/ChapterReadState durable write-through MUST 委托 `HomeLibrarySession` persistence owner，
  MUST NOT direct store `save*` 后手工 replace projection。
  该 owner MUST 经 `HomeLibrarySession` 动态读取当前 library generation，
  并通过窄 `ensureDurableLibrary` capability 在 `recoverCommitted`、
  `resumeCommitted` 与 confirmed execution 的任何 journal lookup/目标 library read 之前完成 durable core open + session adoption；
  MUST NOT 让 bootstrap journal store 与 durable metadata store 分裂，
  也 MUST NOT 持有 `HomeServiceHandoff`、Flutter UI、Widget State 或整个 source-resource gateway；
  transaction result MUST 只暴露结构化状态/计数，展示文案与 SnackBar 等 presentation MUST 留在 UI；
  UI/`part` MUST NOT 重新拥有 `SourceMigrationJournalStore`、
  `runSourceMigrationJournal` 或 metadata cleanup sequencing。
  同源 version relation discovery/page-reuse proof、generic warmup coalescing、
  Reader metadata/version background refresh 与 Reader version authority fingerprint MUST 由独立 version-reuse lifecycle owner 持有；
  该 owner MUST 经 `HomeLibrarySession` 动态读取当前 generation。
  stored successor/predecessor MUST 绑定同一个 concrete library identity；
  若任一 relation read await 期间 library identity 改变，或旧 store 因 adoption 被关闭，
  MUST 整组重读 current library，MUST NOT 将旧 generation successors 与新 generation predecessors 混入一个 Version State；
  current identity 自身的真实存储错误仍 MUST 传播。
  该一致性 MUST 通过 identity revalidation 实现，不得为此引入 `HomeServiceHandoff`/`libraryGenerationChanges`/平行 epoch owner。
  所有 version relation durable write（含 derived page-reuse state）MUST 经 `HomeLibrarySession` 单一 persistence owner；
  写入 concrete library store 或 canonical assimilation 的任一 await 若跨过 library adoption，
  MUST 等 current service adoption 收口并将 relation 重写 current store；
  persistence helper MUST 返回实际稳定写入的 library identity，
  caller MUST 在同一同步 continuation 中再次确认它仍等于 current library 后才推进 session relation projection，
  避免 Future completion→projection publish 间隙跨代；current identity 自身存储错误 MUST 传播。
  owner MUST 只接收 fresh metadata snapshot、verified page identity、
  统一 locator-validity predicate 与 metadata-task scheduler 等窄 capability，
  MUST NOT 持有 Flutter UI/Widget State/ComicDetails DTO/整个 source gateway 或直接读取 app-global coordinator。
  Reader background refresh MUST 由 composition 注入的 scheduler 继续提交到应用共享 NetworkLane priority100；
  携带 `TaskControl` 的 refresh MUST NOT join 无 control 的 generic warmup。
  selected version-view preparation token MUST 由 version-reuse lifecycle owner 持有；UI MAY 只在 route push/finally 调用 start/finish，
  MUST NOT 在 Widget State/`part` 保存平行 `originComicId + Future` map，也不得把 token 升级为 durable authority。
  Source-management UI 在替换 controller active sources 时 MUST 显式追踪上一代与下一代 external source IDs；
  不得以 Mihon/Venera sourceId 前缀决定哪些旧 source 应被替换。用于图标、登录能力或格式特有 UI 的 family 判定不等价于 ownership 判定。
- 书架 manage/batch-selection MUST 由单一纯 presentation state owner 维护 source-aware identity selection；
  Widget State MUST NOT 平行持有 managing flag、batch flag 与 selected-identity set，也不得把该 owner 扩展为 library mutation、dialog 或 navigation owner。
- 首页每张封面 MUST 独立完成请求和显示；一张封面变慢或 durable response 写入变慢，不得阻塞其它已经取得 encoded bytes 的封面。
  冷 miss MAY 先使用 memory source，持久化写入由统一 response cache 后台完成；durable hit MUST 先物化为调用方自持有的 encoded bytes。
  response cache 的文件路径 MUST NOT 暴露给 `FileImage` 或其它长生命周期 presentation 对象；
  `FileEncodedResourceSource` 只允许外部稳定本地文件。durable image persistence MUST 区分 `transient` 与 `retained` 生命周期：
  browse/preview响应 MAY 受 TTL/LRU/maintenance 回收；
  library/history/details cover MUST 在同一 canonical cache key上晋升为 retained，并且 MUST NOT 被运行期容量/TTL整理删除。
  已有有效 durable payload 的晋升 MUST 只改生命周期元数据；transient 副本已回收且内存响应仍有效时，cache owner MUST 在同一 key 后台补写 retained，不再次调用来源。该补写 MUST NOT 成为呈现等待条件；过期或已被精确失效/强制刷新/clear 撤销的旧响应 MUST NOT 被补写复活。
  metadata refresh MUST NOT 以 comic namespace 粗粒度失效 artwork；
  retained cover仅由精确 artwork revision/显式整漫画资源删除/用户清缓存移除。
- `local-folder` 导入 MUST 将 cover 与 Reader 正文 identity 分离：
  若根目录存在经签名识别且文件主名精确为 `cover` 的图片，则它 MUST 成为 canonical cover 且 MUST NOT 进入 Reader page list；
  否则自然排序后的第一张正文 MUST 同时作为 cover。Android SAF/document-tree 导入 MUST 保留正文 `content://` authority，不得仅为封面性能复制整本图册。
  cover 的长期 artifact 必须保留媒体语义：
  JPEG/PNG 等静态 cover MAY 在显式导入/刷新边界生成有界静态 derivative并以 retained response-cache artifact 持久化；
  GIF 或 WebP animation candidate MUST 保存原始 encoded cover 为 retained artwork，
  静态 thumbnail MAY 作为独立 retained placeholder artifact 先于原始动画呈现，但 MUST 使用独立 role/key、不得替代最终 animated source；
  若 placeholder 已命中而最终原始正文也很快 ready，Home MUST 先允许 placeholder 实际产出首个可见 frame 再切换到最终动画，
  placeholder miss/失败则不得阻塞最终 source。
  cover media format/animation hint MUST 随 imported record 与 compact Home snapshot 持久化；
  旧记录可从 matching cover page 恢复该元数据。刷新时 MUST 允许同 URI cover 按 source revision 重建；
  旧记录 MAY 在 Home 首次 miss 时一次性 lazy materialize；
  后续 cold start MUST 优先读取 retained cover artifact，而不是再次依赖 SAF provider 整图读取。
- 首页、书架和详情封面 Presentation State MUST 使用 canonical comic identity，
  不得因 raw Mihon alias、resume chapter、封面 URL 或 loader closure变化被销毁。
  Presentation MUST NOT 自己做定时 retry、first-frame watchdog、ImageCache eviction 或短时 Future join；
  资源重试/缓存所有权唯一属于 `ComicSourceResourceGateway/ResourceCacheManager`。
- 全局网络 User-Agent MUST 是 composition-owned fallback设置，默认采用稳定 Android Chrome UA并可由用户修改。
  来源 request plan显式 UA、browser-session UA或 source-owned client策略 MUST 优先；全局 fallback不得覆盖来源权威。
- Android Mihon宿主 MUST 能执行 extension/source实际返回的 HTTP(S)媒体 URL；
  cleartext兼容能力 MUST 在统一宿主网络策略提供，MUST NOT按 WNACG等具体域名/插件维护静态白名单，也不得把 source返回的 HTTP URL擅自改写为 HTTPS。
  Mihon/network bridge fallback DNS MUST 优先使用系统 DNS 的非空结果并保留系统地址顺序；不得强制 IPv4 前置，也不得用 public-only 过滤破坏 split-DNS/private host authority。
  仅当系统解析失败或为空时 MAY 使用 public fallback，且 fallback MUST 同时支持 A 与 AAAA，不能把 IPv6 从恢复路径中删除。
- Mihon 1.4/1.6 兼容 `NetworkHelper.client` MUST 保留上游可观察的默认网络 ABI：canonical
  `UncaughtExceptionInterceptor` MUST 是 application interceptor 链第一项，canonical `UserAgentInterceptor` MUST 存在并只补缺失 UA，
  canonical `CloudflareInterceptor` MUST 存在且挑战处理 MUST 委托统一 `network_bridge` owner；默认 client MUST NOT 注入 Brotli interceptor。
  `UncaughtExceptionInterceptor` MUST 原样重抛 `IOException`，只把后续 interceptor/source client 抛出的其它 `Exception` 包装成 `IOException`；
  不得在 Reader、Pipeline 或 Download 层模拟上述契约。
- Mihon runtime MUST 在同一 host Injekt scope 注册 `Application`、`NetworkHelper` 与 `Json` singleton；`Json` MUST 与 Mihon app binding 对齐：
  `ignoreUnknownKeys=true`、`explicitNulls=false`。缺失 host singleton MUST 在 plugin-host/runtime 边界修复，MUST NOT 由页面或媒体层兜底。
- source-owned encoded body交付 MAY采用显式协商的sealed file，但source与connection MUST同时声明支持，MUST保留原client/interceptor及完整request语义。
  raw body MUST与IPC envelope独立framing，绑定invocation/source/runtime/payload/locator并校验length/digest；MUST NOT接受调用方任意path或作为durable READY。
  host校验 MUST服从同invocation取消并先保护已接纳文件；校验成功前 MUST NOT发布consumer path。consumer只允许一个正文stream；取消/dispose/close MUST等已接纳物理read退出再释放file，晚到response、source进程换代与host进程遗留文件 MUST有原owner清理路径。
  交付载体 MUST NOT改变持久locator、DownloadId、cache/trust authority或既有正文validator；image admission/Range仍 MUST经过统一source transport，聚合、partial与promotion仍归DownloadJob/DownloadSession。
  body登记 MUST持续到release完成，使并发close加入同一dispose Future；body metadata发布 MUST NOT提前释放尚未退出work的NetLane/invocation容量；sealed output MUST NOT冒充实时network streaming能力或新增retry/eligibility owner。
  原body file owner MAY接纳同步编码器OutputStream；stream MUST有界并在producer返回后关闭再封存。写入/flush/limit/cancel失败即使被producer捕获也 MUST阻止发布，返回时仍 MUST检查取消；调用方 MUST保留原physical work生命周期，MUST NOT在callback返回后继续写入或新增pipe/队列owner。
- Venera变换输出file能力 MUST独立协商，不得因声明transformResource而扩大到loadResource。完整输入、onResponse、canonical1/isolated2及source semantic retry MUST保持原契约。
  变换输出 MUST由原body owner封存并绑定request/source/runtime/payload/locator；worker取消、关闭与completion替换 MUST释放未交付body，physical encode退出前 MUST NOT归还原invocation容量。
  host MUST校验协商的operation及对应payload authority，image/Range/validator/dispose MUST消费原source transport合同；MUST NOT以载体变化更换cache/trust或durable identity。
- Reader页面物理下载 MUST 只有composition `DownloadTransferOwner`一个retry/terminal owner；

  `LiveCoordinator`只协调本Reader demand与decode/upload。
  runtime标记transient/retryable的失败 MUST投影为`ErrorCode.network`并受provider的有界RetryPolicy控制；
  Venera resolver 的rhttp transport failure MUST在Dart→Kotlin→JavaScript bridge上保留typed retryability，
  MUST NOT因错误文本不包含`network/connect/timeout`等关键词而降级成`ErrorCode.source`，
  bridge/runtime也 MUST NOT为此自建第二retry loop。非retryable/source失败与网络重试耗尽 MUST在当前physical transfer demand内终止，
  source snapshot listener、Reader finally或Presentation MUST NOT另行无界重提。
- Mihon stale page-plan 恢复 MUST 与 transport retry 分离。新生成的 opaque page locator MUST 携带 stable chapter/page replay coordinate；
  host-direct request plan MAY 额外声明 `directPlanReplay`，使已有 `SourceResourceTransport` 在 direct transport failure 后一次性调用 `retryResource` 重读 page list，
  但 MUST NOT 因此新建 Reader/Pipeline/network retry owner。runtime-owned `loadResource` 只有在发生非网络、非 verification source failure 时，
  MAY 标记 `sourceResourcePlanReplayEligible`。`SourceResourceTransport` MAY 在同一 logical open 内调用 `retryResource` **一次**，
  重新读取 chapter/page list 并生成 replacement request；普通 SSL/EOF MUST NOT触发该昂贵 replay，而继续归 DownloadJob network retry。
  连接、socket/DNS、TLS或正文I/O失败的具体transport异常即使嵌套native/certificate非IO原因，MUST保持network分类，不得发布source replay资格。
  普通`IOException`包装source/parser错误 MUST继续按来源原因裁决；`UnknownServiceException` MUST保持非网络语义。
  若 source 无 replacement、replay RPC 发生 source failure，或 replacement 再次产生同类 replay-eligible failure，MUST NOT递归 replay，
  MUST 发布 terminal `sourceResourcePlanReplayUnavailable`，由已有 source-generation refresh handoff处理；网络/verification/cancel failure MUST 原样保留。
  Reader 当前页、章节下载命令与 whole-comic queue MAY 在各自既有 owner 内各做一次整章 refresh，但 MUST NOT建立新的 Mihon retry loop。
  显式 `refreshResource` MUST 代表新的 logical resource generation：Mihon runtime MAY 通过 `freshGeneration=true` 重取 page list，
  并在当前 runtime generation 内按 source+locator 有界保留 fresh source request authority；后续 resolve 与 runtime-owned load MUST 共用该 authority，MUST NOT退回旧 opaque request plan。
  same-attempt replay 返回 replacement request 后，紧随其后的 runtime load MUST 执行同一 fresh authority；完整 method/headers/body 与 source client/interceptor/cookie 语义 MUST 保留，MUST NOT降级成通用 HTTP 旁路。
  ordinary replay authority MUST one-shot 消费；fresh-generation authority MAY 在本 generation 内复用。当 source setting/state mutation 推进 resource transport generation 时，对应 source 的 retained fresh/replay state MUST 同步失效。
  升级前持久化且缺 stable replay coordinate 的 `mihon:resource:` locator MUST 在既有 source-locator compatibility gate 判为 legacy，
  并在 Reader/下载消费前强制 source refresh；MUST NOT 仅为 locator schema 升级改写 `sourceRevision`、制造版本或缓存 identity churn。
  旧 v1/v2 locator MUST 在 Reader/下载消费前强制 source refresh 到 v3；v3 transport revision MUST 绑定已验证 extension payload SHA-256。
  App MUST 仅对末尾携带完整 v3 SHA-256 authority 的 runtime-transform revision 比较 durable installed-plugin payload；payload 更新后旧 v3 carrier MUST refresh，普通 HTTP/replay-capable 章节 MUST NOT因此刷新，Reader/Pipeline MUST NOT持有 Mihon replay state。
- 新Reader消费已有committed/promoted physical `DownloadSession`时，
  Reader-local native ingress MUST 以异步 synchronized projection join恢复；
  bounded replay queue MUST按已有numeric priority保护尚未取得source的更高rank demanded entry：
  低rank replay不得占满全部slot并使更高rank entry在local prepare稍后发布READY后仍无法hydrate；
  实现MAY最多保留1个既有slot，且entry进入network/non-idle后MUST立即释放reservation。
  该规则MUST NOT增加总replay并发，也MUST NOT以PageRole阈值重造资格；projection创建/重放 MUST NOT同步阻断 DemandPlan reconcile，
  失败 MUST 只终止该consumer projection而不得降低physical artifact/partial authority。
  Reader source listener MUST保存logical DownloadId当前实际绑定的physical session/projection generation；
  纯consumer media demand释放 MAY 丢弃coordinator-local source-kind snapshot，
  但 MUST NOT向Pipeline发布`ContentKind.unknown`作为“该页不再是WebP/原kind”的负证据；
  只有physical session/projection generation真实替换或`SourceEpoch`变化 MAY撤销旧kind evidence。
  同logical id重新解析到不同physical session、same DownloadId对应新的DownloadSession对象，
  或同一DownloadSession原地reset使`SourceEpoch`变化时，旧Reader-local encoded generation的source-length watermark、
  decode/upload/output binding MUST机械失效；
  新epoch首次`sourceReady` MUST无视普通progress quantum立即唤醒waiting decode，后续增长才恢复量子合并，MUST NOT因旧epoch listener缓存吞掉wake。
  synchronized replay的consumer-visible publish MUST以replay开始前的projection snapshot作为事务基线，
  不能在bytes/kind/revision已更新后才截取`before`而吞掉非native source变化；
  `ContentKind.unknown`变为`fallback/gif/webp`本身就是decoder可消费的新分类证据，
  即使当前prefix尚未sealed且fallback/gif永不产生native `sourceReady`，
  source listener仍 MUST立即唤醒waiting decode，不能依赖后续手势/plan revision碰巧重跑。
- Reader navigation/current/requested page MUST 独立于 DecodeTarget、download owner与pipeline reconcile生命周期；
  用户强制重新加载完成physical generation reset后，Reader MUST只重建目标asset的presentation subtree并重新消费只读PageStream/PageOutput，
  MUST NOT重建ReaderController、整本page slots或DemandPlan；
  Reader observation callback MUST enqueue后在ordinary event turn再reconcile，
  MUST NOT以microtask priority在当前frame之后抢占platform/input/vsync event；
  pipeline错误不得阻止viewport jump/page-request acknowledge。
  Reader-local viewport/playback projection MUST先于/独立于demand reconcile推进，即使某lane reconcile失败也不得因此丢失viewport事实。
  DecodeTarget变化 MUST 更新既有PipelineController target并通过后续enqueue observation从当前DemandPlan增量重算，
  MUST NOT detach binding或把download demand先清空再重建，并 MUST复用同一个ReaderController。
  ReaderController broad notification MUST只表示direction/rotation/request/scrub等command；
  currentIndex report MUST通过独立窄projection发布，MUST NOT唤醒command consumer或整套Reader controls。
  Reader固定底部控制区的页面/旋转/收藏/缓存按钮 MUST NOT 因当前媒体从unknown/static分类为animated而重新布局；
  动画播放与倍速控制 MUST 作为独立presentation control出现。Reader顶部 MUST 提供“强制重新加载当前页”最终手段；
  该动作 MUST 通过composition/Pipeline owner quiesce当前physical task、
  reset同一个physical session generation、使被拒绝的canonical physical READY/partial不可立即回流并暂时禁止exact/canonical/equivalent durable fallback，
  再从fresh source恢复；Reader自身 MUST NOT直接删除文件或实现第二套retry/cache authority。
  若实际presentation `storageId`或requested exact durable binding任一表明当前页是显式下载形成的pinned/manual状态，
  强制重新加载 MUST保留requested exact binding、pin及结构化离线文件，fresh physical generation只服务当前presentation且普通automatic cache handoff MUST NOT静默覆盖该pinned exact；
  只有显式chapter/whole-comic required download claim MAY继续拥有exact durable replacement。
  若强刷发生在正在下载的页面，existing required claim MUST保留在同一个physical DownloadSession上，
  旧attempt退出后以新epoch重新admit，不得创建第二physical owner或第二retry budget。
- Vertical continuous Reader MUST keep per-frame coverage/velocity/logical-position inside Reader geometry/presentation.
  Pipeline control observations are discrete:
  unchanged current/stable, target page, visible-page membership and active interaction class (dragging/scrolling/settling) MUST be treated as a control no-op;
  DecodeTarget dirtiness still forces the next observation through.
  This filtering MUST NOT apply to non-vertical/discrete paging semantics.
- ReaderBinding MUST NOT rebuild upload page-index maps or re-run PlaybackGate for coverage-only motion when resolved ViewportState and Pipeline revision are unchanged.
  PipelineReaderSession MUST run page-stream/output/artifact/control synchronization only after a real plan revision or current/decode-target identity change.
  High-frequency readerObservation/pageTransition/layout diagnostics MUST be sampled at semantic edges/bounded heartbeat and MUST NOT become a per-frame control-plane owner.
- 非file且无authority的opaque资源URI MUST NOT通过payload中的hash或路径片段推断standalone physical identity；已验证canonical projection的解析不受该形状过滤影响。
- 不可变章节记录 SHOULD 复用其只读 manifest 元数据投影；真实 locator/page payload 更新 MUST 使用新记录，MUST NOT 因投影复用吞掉同 revision 的变更。
- Source-confirmed version-family reuse MUST use a stable opaque `VersionFamilyId` and direct exact-page→canonical-physical projection.
  `DownloadId` MUST remain the exact provider/logical identity for URI/revision/validator/manual pin/export semantics;
  a verified cross-version page MAY resolve to `PhysicalMediaId.canonical`,
  but latest/shelf/download head MUST NOT rename that physical identity.
  Canonical mutable partial and canonical READY ownership MUST be keyed by the physical identity;
  provider validators MUST remain exact/provider-scoped.
  Cache management MUST count a shared exact+physical immutable body once by bytes,
  MUST include physical-only READY/partial state in global inspect/trim/clear,
  and MUST preserve canonical physical metadata while any surviving exact READY binding still owns the same object.
  Global physical clear/trim MUST atomically revalidate the physical LRU generation and exact READY references before removing canonical routing;
  a stale maintenance snapshot MUST NOT win over a later exact bind/touch.
  显式exact artifact失效MUST保留对新binding/body authority的保护，但MUST NOT因仅maintenance `touchedUs`变化而保留同一已指定失效的正文。trim、maintenance eviction及其它快照比较MUST继续保留recency保护。
  A persisted canonical coordinate alone MUST NOT reactivate revoked cross-version proof for a new exact claim.
  Automatic promotion MAY commit the exact durable object even when canonical binding conflicts with an incumbent physical owner,
  but that promoted epoch MUST then fail closed to exact routing,
  MUST NOT retry the same canonical bind indefinitely,
  and MUST leave later canonical repair to the control-plane reconciliation/backfill path.
  Historical exact partial→canonical backfill MUST serialize source validation,
  canonical copy, post-copy coverage proof and exact retirement against mutation of that exact row.
  Per-family bulk deletion MAY remain unsupported until an ownership-aware delete plan can preserve manual/pinned exact state.
  同一 canonical `PhysicalMediaId` 已存在可读 READY `physical_media_artifact` 时，
  持久层 MUST 将同 key 的 `physical_partial` 视为冗余而非第二份可见进度 authority：READY bind/open MUST 安排 targeted retirement；
  `openPhysicalPartialDownload()` 等 read/recovery API 若观察到 READY dominance MUST 返回无 partial，
  并仅调度同一 persistent retirement owner，MUST NOT inline 删除 body/row。
  store open MUST 以非阻塞、metadata-only 的 SQLite key-intersection sweep 收敛旧版本遗留 overlap，MUST NOT 扫 SAF/Direct 文件树。
  retirement MUST 重新确认 READY generation、跳过 borrowed hot partial，并先删除且确认旧 body/sidecar absent 后再删 row；
  I/O失败 MUST 保留 row，Reader lifecycle/App exit MUST NOT拥有这一步。
  在 retirement 真正完成前，Download Manager、`inspectArtifacts()`、
  capacity reservation 与 trim candidate projection MUST 已经让 READY 遮蔽 same-key partial；
  该 partial MUST NOT增加可见 partial 页、logical bytes、entry count 或 trim pressure。
  只读 projection MUST NOT为了达到这一结果删除文件。
  显式 clear MAY由 persistent maintenance 清掉冗余 body/sidecar，但 MUST NOT把它报告成第二个 cache eviction。
- Download demand MUST按consumer scope独立持有；应用级`PersistentDownloadComposition` MUST持有唯一durable store、
  `ArtifactCacheManager`与`CompositionDownloadTransferRuntime`，
  Reader current/prefetch及显式chapter command MUST对exact `DownloadId`共享同一physical `DownloadSession`/writer/network/retry/hot partial，
  whole-comic MUST只聚合chapter command而不得建立第二physical owner。
  同一exact id已有queued/active task时，revision变化 MUST只更新该task priority并保持task key稳定。
  runtime source/media evidence MAY更新事实缓存，但只有当最终DemandPlan的role/resource/priority/reason/watermark/flow/keep等调度语义改变时才 MUST提交新policy revision；
  纯诊断/evidence计数变化 MUST NOT进入Coordinator。`expirationRevision` MUST只作为surviving demand的liveness metadata原位刷新，
  MUST NOT参与Download/Decode/Upload的scheduler diff equality，
  也 MUST NOT单独触发cancel/submit/follow或physical `replaceDemands`。
  一个accepted `DemandPlan`的sessions reconcile MUST作为单一scheduler transaction：
  Net/Decode/Upload mutation MUST先完成到最终权威state，任何lane MUST NOT因同一plan内逐项priority/submit/follow反复pump intermediate state；
  outer reconcile完成后每个lane至多执行一次由该事务请求的pump。
  physical `DownloadTransferOwner.replaceDemands` 内部同样 MUST把同一consumer事务的local-preparation pump与prepared-network admission drain合并到整批mutation末尾，
  不能为每个scheduling-only claim change重复扫描pending集合。
  纯existing-scope download priority变化 MUST作为scheduling metadata直接迁移，
  MUST NOT通过完整`DownloadSnapshot`广播唤醒不消费priority的media/session lifecycle observer；
  新增/最终撤销claim及真实transfer/content状态变化仍 MUST正常通知。
  `DownloadSession` diagnostics Trace emission与`DownloadSnapshot` publication MUST分离：
  Trace helper MUST NOT隐式notify；existing-scope priority、flow-control、read-permit、resume、
  source/rejection等纯诊断 MUST发布0个snapshot，新增/最终claim及任何真实snapshot字段变化 MUST由拥有该mutation的状态边界显式且恰好发布1次；
  committed-byte progress MAY继续按既有source-progress quantum有界发布。多个claim的有效priority MUST取最大值而不是求和；
  priority只决定竞争顺序，required completion MUST独立决定低优先级显式下载是否必须最终完成costly full-body catch-up。
  一个consumer退出/取消 MUST只撤销自身claim；当最后logical claim归零而network task已经active/admitted时，
  owner MUST保持同一task key、把priority迁移到rank 0并把scheduler demand state标记为`demanded=false`；
  working-set detach MUST NOT直接cancel。仅尚未admit的queued task MAY直接移除。
  已经admit且最后claim归零的task MUST在下一安全read boundary释放body-read permit并park同一live response/task；
  只要live source response仍保留，task MUST继续占有NetLane transport/source lease。
  重新获得claim时 MUST在同一task/response上恢复`demanded=true`并重新竞争read permit。
  `demanded=true` flow-paused response仍优先保留同一live response，但它不再拥有超越调度rank的永久transport lease豁免：
  只有新的demanded task因真实transport lease饱和无法admit，且incoming priority按同一`NetPolicyRank`（base priority + scheduler-owned restart-cost retention）至少超过该parked response一个`preemptionThreshold`时，
  NetLane MAY以typed `ranked-transport-lease-reclaim`结束该lower-ranked retained response；
  仍持body-read permit或已请求resume的response MUST NOT通过此路径回收。
  `demanded=false`且保留live source response的task不得由第二个parked数量cap管理，
  在相同真实lease pressure下仍 MAY优先以typed `inactive-transport-lease-reclaim`结束。
  无pressure时不得仅凭`openingElapsed/inactiveElapsed/committed=0`猜测未来是否回访并新增固定detach超时；这些状态在快速回访与永久离开之间不可判别。
  NetLane MAY暴露read-only diagnostic snapshot，owner MAY记录inactive enter/reattach/evict结局，
  但其active/opening/inactive时长、response状态与restart-cost MUST NOT成为新的admission/retry/reclaim输入。
  Reader/3/7 MUST NOT配置transport/socket retention容量；Range、flowTarget、Reader距离或role均不得形成第二套normal reclaim资格。
  `residentBodyBacked` MUST只表示正文由外部immutable authority可重放，不得推断durable cache已拥有正文；
  `ByteResponseDisposition.durableImmutable`与`ByteResponseBodyAuthority` MUST正交，
  只有artifact-cache authority才可证明durable body ownership。
  physical session的generation-local source-metadata prefix MUST继续限制为最多64B并只承载encoded metadata。JPEG等尺寸marker可能晚于64B时，physical session MAY在source canvas尚未知期间维护独立、最多64KiB的一次性dimension probe；该probe MUST只用于解析width/height，成功后立即释放，MUST NOT扩大metadata ABI、正文缓存或body authority。
  对已经由persistent owner完成sealed/exact-length/provider preflight的immutable generation，
  composition MAY以`physical media id + exact length + checksum algorithm + checksum`等价形成opaque acceleration key：
  中央`ArtifactCacheManager` MAY保存bounded decoder bootstrap prefix，
  `ResidentReplayReaderPool` MAY保存最多16个idle已验证bound reader/descriptor作为hot-session之外的second-chance；
  两者 MUST NOT建立或替代body/durable authority，也 MUST NOT因prefix命中跳过provider proof。session只持lease；
  reset/retention eviction MUST归还lease，generation key变化 MUST miss，
  range read失败 MUST退休该descriptor，composition close MUST最终关闭pool。
  artifact-cache durable body一旦确认authority MUST以`responseRetained=false`同时释放NetLane network body-read permit与transport/source lease并继续本地读取；
  其body带宽 MUST只由`ArtifactCacheReadScheduler`调度，不得与remote NetLane资源双重计数。
  sealed persistent stream MUST只依赖既有seal proof加本次locator/existence/exact-length preflight，
  MUST NOT按Reader访问重算whole-file checksum；full-read校验 MAY重算CRC。显式full-read发现同长度CRC不一致时 MUST 以结构性`checksumMismatch`退休该物理replica，并在仍有sealed replica时继续验证，不得仅因一个副本损坏删除logical artifact authority。
  `PageAsset.checksum` MUST 保持source-declared algorithm namespace；只有声明算法匹配且格式合法时 MAY约束transport completion，即使其算法为`crc32`也不得直接冒充artifact seal proof。
  backend MUST显式声明stream/full-read integrity basis，joined materialization MUST保留实际source operation的basis，
  Trace MUST区分`sealedMetadataLength`与`crc32Verified`且 MUST NOT据此形成调度策略。
  source-resident promotion MAY保持session artifact为空且不得因Reader展示自动持久化；
  显式durable command完成前 MUST通过composition replay authority验证boundary/validators并materialize到唯一ArtifactCacheManager/store且确认durable artifact可读。
  promoted session 的 active presentation read 与同 exact identity durable handoff 交叠时，若当前 generation 已发布 exact promoted hot bytes，
  MUST 直接消费该 projection，且在 store commit 前保持 `durable=false`；它 MUST NOT建立 durable lookup/cache-management authority。
  只有当前 generation 无 exact hot bytes 时，仍 active 的 caller 才 MUST 等待 mutation barrier 后重新选择 authority；
  caller 自身取消 MUST保持终局且 MUST NOT重试。
  每个Reader仍 MUST通过自己的`DownloadIngressProjection`消费encoded prefix，decode/upload/presentation保持局部；
  Reader route 的短期 re-entry retention MAY以TTL 2分钟、LRU最多2个exact session保留章节级控制与可重建transfer/encoded authority；
  第三个不同key MUST淘汰最旧会话；route退出 MUST立即撤销demand与presentation claims，由现有Coordinator退休Reader-local媒体；
  idle的Decode/Upload、cursor/canvas、frames与Ingress/Source MUST立即释放；仍在执行的已取消任务 MUST等原lane真实退出后自动释放，Pipeline MUST NOT提前evict；
  已取消任务真实退出后 MUST成为media-empty shell；不得让已无 presentation demand 和执行任务的 cursor 通过 source `Arc` 延长整页 encoded body 的 native residency。
  快速重进 MAY从保留的 encoded authority重新 decode/upload首帧，不得以保留 native media working set 换取零 decode 重进。
  deferred resident range hydration若在某一physical `SourceEpoch`失败，
  MUST将该Reader-local replay视为该epoch的terminal failure，
  MUST NOT因未满足的requested length、role/priority churn或`whenComplete` tail对同一epoch自动重试；
  只有physical epoch换代 MAY重新尝试。成功attempt期间新增的更大decoder-owned target MAY在该attempt成功后合并为一次后续hydration。
  late projection replay默认 MUST在追平physical committed boundary期间保持source不可见；
  但已sniff为WebP的nonresident hot partial MAY先发布该Reader自己的source-appropriate最小decoder probe（remote默认256KiB），
  再在同一native source上增量追平artifact suffix并仅在稳定边界后加入live fan-out。
  完整source-resident immutable generation在seal后若future Reader具备artifact-cache或`file/content/asset` exact-range replay authority，
  也 MUST启用deferred resident ingress：初始只hydrate 256KiB并发布source，后续仅按decoder evidence扩range；
  不可重开provider source MUST保持非deferred。
  physical `DownloadSession`上的decoder-owned playable/first-frame-required evidence MAY继续约束transport flow-control，
  MUST NOT决定任何后续Reader的late-join/rebuild replay watermark，也 MUST NOT作为partial持久化/有效性事实。
  early publish后 MUST NOT通过rebuild/reset替换已对decode可见的same-generation source；
  physical partial availability、network need与Reader-local decode availability MUST保持独立。
  跨版本hot writer MAY仅通过acquire-time verified physical alias共享：
  新exact demand尚未创建session，且direct verified equivalence唯一指向已有有authority的physical session时可在acquire前join；
  两个已经存在的physical session MUST NOT事后merge，source-resident且非artifact-cache authority的body MUST NOT跨版本join。
  共享后claim MUST保留自己的exact URI/source bucket；
  committed partial MAY由physical session跨direct verified equivalent request共享，
  但resume validator MUST绑定到实际产生它的provider exact URI，
  MUST NOT把physical anchor或其他provider的ETag/Last-Modified用于当前URI的strong Range；
  scope不匹配时 MUST保留partial并按既有validatorless overlap规则验证continuity。
  显式durable command完成前仍 MUST materialize自己的exact durable ID。
  若required exact ID与physical session anchor不同，durable handoff MUST直接materialize required exact target，
  MUST NOT为了完成该command先强制持久化physical anchor再复制。
  verified relation MUST只在新的physical acquire发生时影响transfer identity；
  artifact promoted commit MUST NOT通过observer异步取消、重启或改写任何已经存在的independent physical session，
  Reader/consumer/cache均 MUST NOT持有late takeover委托。physical async prepare MAY恢复cold/session-local artifact；
  若prepare后session已promoted或完整partial可在无transport条件下本地seal/promote，
  TransferOwner MUST在provider transport lookup/lease及`downloadStarted`之前完成短路，
  MUST NOT把local completion记为network start。`downloadStarted` MUST只在仍需要真实provider transport attempt时记录。
  active provider lease MUST只属于当前physical network task。
  logical provider claim撤销 MUST NOT单独取消一个已经admit且仍physically active的provider attempt；
  剩余claims只通过同一NetLane task迁移aggregate priority。
  active task启动时 MAY从consumer取得显式task-retainable transport capability；
  只有该capability与consumer close生命周期独立时，provider consumer dispose MAY保留attempt并继续同一physical writer/partial。
  consumer-bound transport在consumer dispose时 MUST取消active attempt并等待writer物理退出；
  Reader-owned `IoTransport` MUST始终属于此类。Pipeline MAY只对loader-backed URI提供retainable capability，
  sessions MUST仅消费通用capability而不得按Venera/Mihon/source类型分支或维护第二transport registry。
  provider exact MUST在physical network task admit后保持到attempt完成、失败或其consumer-bound transport真实dispose；
  verified-equivalent logical exact/current/rank变化 MUST只迁移同一个NetLane task priority，
  MUST NOT为了切provider URI取消并重开已admit attempt。task-retained transport仍 MAY越过provider consumer dispose；
  consumer-bound transport MUST维持cancel+idle硬边界。
  NetLane policy rank MUST只决定physical task slot/preemption并拥有restart-cost retention，
  不得再兼任provider request replacement。
  costly full-body catch-up MUST由单一transfer rank policy将preserved-prefix成本映射为cost rank并比较demand rank；
  required completion MAY提高demand rank。
  `DownloadSession` MAY发布仅供观测的transient transport cursor/attempt sequence；
  该cursor MUST由`DownloadJob`按实际response消费推进，可在Range→200 prefix replay时落后于authoritative committed partial，
  但 MUST NOT持久化或参与resume/identity/durable/rank。Reader MUST在同一横向尺度只读展示两者：transport wave覆盖0→当前cursor；
  cursor落后于authoritative partial时只把cursor→partial末端画成直线，追平后不得保留独立partial段。
  显示比例 MUST优先消费durable total或本地encoded container可立即声明的total（WebP RIFF declared length可作为projection-only hint）；
  真正没有尺度时不得制造固定宽度/虚线partial。
  current-attempt response total MAY临时提供显示尺度，但任何display hint都不得取得resume/seal/cache authority。
  颜色 MAY按当前transport speed变化，但UI MUST NOT据此控制scheduler/retry。
  Reader role名称、1000、820/900等策略阈值 MUST NOT散落在`DownloadTransferOwner`控制流。
  版本页复用 MUST 收口为composition-owned direct candidate authority，而不是source-version head替换：
  `HomeLibrarySession` MUST以durable verified relation + 当前visible/按需hydrate manifests原子发布bidirectional direct candidate projection；
  relation本身 MUST NOT把用户请求的logical `DownloadId`改写为更新版本，
  也 MUST NOT改变partial/READY/manual-download的exact durable owner。
  `ArtifactCacheManager` READY lookup、`PartialDownloadHandoff` cold partial restore与`CompositionDownloadTransferRuntime` hot acquire MUST消费同一`VersionPageAuthority` candidate set；
  只有候选确实已有可复用physical state时，新exact demand MAY在acquire前join carrier。
  若logical exact本身已有session且仍demanded，则本次acquire MUST继续使用exact physical；
  若exact仅idle/retained且无consumer demand，则它只作为verified physical candidates之一，
  MUST与等价READY/hot/partial按physical authority与已提交长度共同择优，
  允许下一次demand使用更先进carrier，但 MUST NOT merge/rebind两个已存在session，旧exact仍由既有retention独立回收。
  跨版本partial复用 MUST清空foreign provider validator，显式durable completion仍 MUST materialize调用者自己的exact target。
  Reader MUST只负责确保compact relation所需manifest已hydrate/缺失mapping的bounded proof，
  不得按whole overlap展开page pair、批量查询candidate page keys或逐页materialize equivalence edge。
  初始source-owned related-version proof MUST使用固定预算而非page-count预算；
  当前默认最多8个predecessor位置，首/中/尾offset一致时可形成低成本affine coverage，
  出现mismatch/offset分歧只 MAY在相关区域继续二分，预算耗尽后的未知区域必须保留为gap并交给后续正常浏览/下载自然evidence纠偏。
  版本页正文复用coverage MUST统一表达为predecessor-index空间的verified affine interval集合，每段独立携带offset；
  whole-overlap只是单区间退化情况，gap MUST保持未授权，相邻同offset MAY合并。anchor indexes仅为bounded proof诊断；
  byte-reuse consumer MUST使用verified intervals求唯一对应index，MUST NOT直接用mapping级`successorOffset`授权正文。
  多跳relation MUST通过interval坐标平移与交集组合，revision断裂或同一predecessor范围产生不同offset时 MUST fail-closed。
  运行时version resolver MUST NOT为整章构建pageId/URI→index表；
  manifest-aware caller MAY在`DownloadId`携带不参与key/JSON/equality/hash的非持久`pageIndexHint`，
  resolver只能在该hint与目标manifest slot的exact pageId+URI同时一致时使用其O(1) index，否则 MUST exact-only。
  已存在的Reader/download source open MAY把direct request正常解析后自然获得的strong media identity作为增量relation evidence，
  但 MUST NOT为此增加source resolve/network call；
  runtime-transform、client-runtime fallback或无法确认最终direct body URI的recovery MUST NOT产生该identity。
  evidence owner MUST使用有界瞬时observation集合配对相关版本，匹配可新增/扩张局部verified interval，不匹配只能切裂当前实际比较的pair；
  只有interval真实变化才 MAY持久化derived relation，重复已覆盖match MUST零写盘且不得广播Home projection。
- production `CompositionDownloadTransferRuntime` 的 fresh mutable partial MUST 写入由App私有support identity稳定派生的 recoverable staging root；
  该root MUST与用户选择的SAF/POSIX下载目录正交，并允许任务界面移除/进程终止未执行Dart cleanup后，
  下一runtime按同一deterministic `DownloadId` artifact path先执行`DownloadSession.restore()`恢复磁盘上实际存在的连续prefix。
  普通App background/paused MUST NOT为了保住hot partial复制整段正文到durable store/SAF；
  retention pressure、显式durable completion或真正runtime teardown仍 MAY按既有handoff持久化。
  retention pressure 的 promoted/partial victim MUST在对应durable handoff成功后才退休；若其正文由session自己的recoverable Artifact持有，退休 MUST删除该hot `.part/.bin`与sidecar，使32-session/256MiB idle预算对应实际workspace正文而非仅registry数量。borrowed durable backing与resident body MUST只release lease/descriptor，MUST NOT由hot-retirement路径删除。`DownloadSession.dispose()`的普通默认行为 MUST继续只是生命周期关闭；hot body discard必须是retention owner在handoff成功后的显式意图。显式required completion MAY绕过50MiB speculative encoded budget并让active prefix超过该阈值；这不是idle retention额度，也 MUST NOT通过把每个network chunk同步写SAF来“修复”。现有SAF whole-prefix transactional partial writer MUST NOT被当作2MiB stride spill，因为反复从0重写会形成provider写放大。
  decoder MUST自行消费恢复出的partial并判断当前可解码边界；playable/needMoreData事实 MUST NOT成为partial persistence、
  checkpoint或network admission条件，transport续传仍只由既有demand/NetLane authority决定。
  无validator/Range被忽略而进入完整200正文catch-up时，只有在已完整读够旧partial长度且CRC明确证明新正文前缀与旧generation不一致后，
  physical owner MAY丢弃该旧generation并执行至多一次offset-0 clean restart；
  普通`resumeRejected`、短读、取消或未完成proof MUST保留旧partial且不得被加入通用RetryPolicy。
  borrowed durable spool 的progress checkpoint MUST在不pause当前writer的前提下先flush Artifact，
  再把该次flush后捕获的精确committed length经`DownloadCacheMutationOwner`发布到persistent index；
  checkpoint完成后继续append但尚未进入下一checkpoint的bytes只是未提交crash tail。
  cold mutable-partial open MUST以indexed checkpoint为恢复上界：physical body短于checkpoint属于corruption；
  body长于checkpoint MUST保留并只暴露indexed prefix，POSIX adoption MUST在取得独占borrow后截去额外tail再继续，
  MUST NOT把额外tail自动提升为durable bytes，也 MUST NOT因`file.length != index.bytes`删除整个有效partial。
  READY/sealed artifact的exact-length proof不受此规则放宽。
- Reader presentation 对实际取得的页面正文发生文件头、decode 或 presentation 语义拒绝时 MUST 把失败报告回 Pipeline，而不是只在 UI 显示错误；
  `ContentKind.fallback` 或“不是 WebP/GIF”本身 MUST NOT 被当作 artifact 损坏证据。
  `PipelinePresentationRasterCache` 的 ordinary residency eviction / demand loss MUST NOT 旋转 presentation identity；
  Pipeline 只撤销该 identity 的 external-presentation satisfaction，mounted adapter MUST释放本地 binding/attempt并允许later same-identity grant重新attach/decode。presentation widget MUST NOT识别private resident-provider类型或直接访问process-global raster cache；local_media_ui composition adapter统一返回最终provider：exact resident handoff原样返回，否则才执行viewport resize并wrap入唯一managed cache。mounted UI MUST NOT再次实现resize/cache ownership分支。
  external presentation MUST以单个不可变 grant 原子发布：grant MUST内部绑定exact `DecodeId`，Presentation可见投影仅含cacheIdentity、unavailable/requested/ready与acknowledgementToken；兼容requested/ready/cacheIdentity只可由该grant派生。首帧完成 MUST从requested直接切到ready并保留同一ack token，不得通过分步setter暴露瞬时双false revoke；ordinary same-cache-identity revoke/regrant MUST取得新token。
  mounted first-frame MUST把实际消费的grant交回`PipelinePageOutputStream.reportExternalPresentationFrameReady(grant)`；output MUST先验证ack token仍为current，随后由pipeline_runtime读取grant内部私有DecodeId完成session satisfaction。Presentation MUST NOT获得DecodeId getter，也 MUST NOT只凭PageAsset反查“当前”DecodeId。mounted adapter 的 first-frame/error/recovery/final-state MUST绑定当前不可变 presentation attempt（local epoch/token + grant token + exact read authority）；旧attempt异步结果在失去current身份后 MUST静默退出。
  managed raster decode failure MUST先保留当前consumer的error channel与原read authority，MUST NOT在error交付前伪装成ordinary residency eviction同步撤下consumer。
  raster residency 消失本身不是 encoded-body failure，也不是 SourceEpoch / ArtifactCache mutation-generation change；
  无 exact artifact authority 的 presentation error MUST NOT 自动 reset durable/source generation。
  只有当失败携带该次 presentation read 的 exact `ArtifactCacheManager` authority 时，Pipeline MAY 每页每 Reader session 至多自动执行一次 durable artifact 自愈；
  显式用户“重试” MAY 在自动尝试之后再次请求 fresh bytes。durable 自愈 MUST 由 composition `DownloadTransferOwner` 原子协调：
  先阻止该 physical id 新 admission，取消/等待 cold local preparation 与既有 NetLane task 退出，
  再按 presentation read 时捕获的实际 `storageId + mutation generation` 条件失效该代 memory+durable authority。
  若被拒绝正文已经成为当前 `DownloadSession` promoted final，recovery reset MUST 删除该 physical final 后再 restore；
  普通 reset MUST继续默认保留 promoted final，不得把 destructive recovery 语义扩散到普通 cache/shared-binding lifecycle。
  失效成功后，`ArtifactCacheManager` MUST 对该 logical id 及其当前 resolved physical id 建立 transient fresh-source quarantine：
  `PartialDownloadHandoff`、memory/persistent lookup、
  backend 内部等价 fallback、direct verified equivalent reuse 与 `containsBackendExact` 均 MUST 在该fresh generation收口前视为 miss，
  因此canonical physical READY/partial不得在reset后立即把同一旧正文重新灌回session；
  equivalent sibling 自身的binding/physical bytes MUST NOT因此被删除。quarantine 建立时 MUST处于 unarmed 状态；
  只有physical reset以及针对该canonical physical generation的READY/partial路由失效完成后composition才可arm该group。
  普通unpinned cache可由store开始时已经armed的fresh durable write解除quarantine；
  若exact backend表明该页是显式pinned/manual download，presentation recovery MUST保留exact durable binding并允许fresh promoted physical epoch以hot-only方式解除quarantine，
  不得把Reader强刷变成offline download replacement。随后在保留既有 consumer claims/demand 的前提下重新 admission。
  若 failure 到达时 generation 已变化，旧 failure MUST 只触发当前 authority 重载，
  MUST NOT 删除新 artifact 或 reset 新 physical generation。task-retirement continuation MUST NOT 在失效/reset 完成前抢跑。
  Presentation/UI MUST NOT直接创建 transport、reset session 或自行实现第二套 retry。
- exact ready durable artifact 若已由 persistent store 完整读取并以相同长度恢复到当前 ephemeral physical session，
  则该完整读取 MAY 形成同 exact id / 同 physical epoch / 同最终长度的短期 durable-restore proof；
  session 随即 local promote 时，persistent artifact handoff MUST 直接以此 proof 判定“原 durable final 已存在”，
  不得再次执行同一 backend 的 platform `exists + length` preflight。
  该 proof MUST NOT用于 partial、verified-equivalent body、
  后续追加过字节的 session、reset 后 generation 或普通 Reader cache lookup；
  这些路径继续要求既有 locator/existence/exact-length 物理 preflight。
- TransferOwner 的 provider lookup、retained transport解析、无 transport 本地完成与 body attempt MUST 位于同一错误生命周期；
  任何失败路径 MUST释放 writer、provider lease和task key。
  network setup MAY进入有界 recovery rounds，非 retryable 或耗尽 MUST发布 typed terminal failure且 unchanged demand MUST NOT热循环。
  本地完整 partial seal/checksum 失败 MUST先关闭 writer并重置该损坏 generation，再进入正常 provider admission；
  MUST NOT对同一坏 partial反复执行 local completion。
- 整本队列持久化 MUST写入 effective storage-root/SAF-tree identity；
  identity变化时 persisted complete MUST清空并按当前 chapter-download authority reconcile，MUST NOT沿用旧根完成状态。
  pause/cancel/close 对底层 cancel 与 active run MUST有界等待；queue JSON MUST以保留旧完整文档的同目录临时文件原子替换。
  内存章节后端的 manual download（含取消/失败 partial）MUST受 pin 保护而不被 trim/clear 删除，
  最后一个同 comic 章节删除后 MUST释放其 memory placement。
  生产显式下载 MUST在任何 probe、placement或字节 mutation 前完成 durable service handoff，失败即终止。
- Reader page 的 scheduler cancellation/priority MUST 跨 `DownloadJob -> cache/read-through transport -> source request-plan -> external runtime` 保持同一 task identity。
  任何透明wrapper在下层支持`ControlledTransport`时 MUST保持该capability与同一个`TaskControl`，cache miss不得退化为无control的`open()`。
  Venera MAY 为JavaScript安全保持单 invocation context，但其内部排队 MUST在permit transfer时尊重实时priority并丢弃cancelled waiter；
  若同一scheduler `TaskControl`在waiter存续期间发生priority变化，gate MUST保留实时priority用于permit排序；
  只有waiter从低于1000跨入current=1000，或controlled active从current=1000向下跨出且队列中已有新的current=1000 waiter时 MAY动态重新评估preemption；
  普通780↔900变化与非current active demotion MUST NOT触发不可逆cancel。runtime MUST NOT写回priority或创建独立policy。
  active controlled invocation取消 MUST下沉到requestId cancellation。
  Venera controlled request-plan gate SHOULD以previous=780作为pressure floor并继续要求至少40分rank差：
  780对760不得抢占，780对明显更低rank active work MAY请求取消。
  若唯一active invocation没有`TaskControl`（例如Reader首帧后启动的普通metadata `loadChapter`），
  priority>=780的受控page request-plan排队时 gate MUST允许请求取消该generic active；
  该generic调用不得因为缺少rank而永久压在foreground page plan之前。此取消仍不得提前释放唯一permit，必须等待旧invocation物理退出。
  `loadEp`的page identity与按需`onImageLoad` request-plan MUST和最终图片body transport区分；
  最终无状态图片HTTP由`SourceResourceTransport`/host transport执行，
  `__zicCancel(requestId)`只取消JavaScript plan invocation及其bridge-scoped工作，MUST NOT成为最终图片HTTP的第二cancel owner。
  Venera requestId cancellation MUST沿原resolver transport取消该request所属已接纳HTTP请求与响应正文读取；
  isolated Dart的rhttp `CancelToken`只负责HTTP执行，Kotlin/JS保留requestId grouping、Cookie/manual redirect与source cache authority；
  默认系统DNS的物理退出 MUST有独立证据；HTTP Future取消、native finally或loopback成功均不得替代该验收，也不得为此新建DNS/transport owner。
  Venera bridge 的 `delay` MUST为异步、按requestId可取消的 JavaScript timer/Promise，
  MUST NOT以 native `Thread.sleep` 阻塞 WebView bridge线程。
  单上下文 invocation permit MUST等JavaScript真正 `finished(requestId)`且该request所有已接纳native bridge call物理退出后才释放；
  仅向Dart返回“cancelled”不得提前制造第二个并发JS invocation。不得用独立FIFO覆盖NetLane决定，也不得增加Venera并发来模拟抢占。
  source response/request MAY携带只读stage diagnostics用于trace，
  包括gate wait、runtime invocation、JS hook、hook内bridge network与host-open；
  scheduler/retry/cache MUST NOT依据该观测元数据决策。
  通用 external-runtime invoke function type MUST NOT因为该观测需求增加 timing callback；
  gate/runtime timing MUST限制在 resolve-resource 专用私有 invocation seam，普通 browse/details/account不得依赖该内部诊断。
  Venera HTTP文本与`Convert.decodeUtf8` MUST按参考UTF-8解码消费一个开头的BOM，MUST保留正文中的U+FEFF及原始二进制响应；GBK解码MUST保持独立。
  Venera source传给`Network.*`的`cache-time`与`prevent-parallel` MUST作为runtime network控制字段消费并在origin HTTP前移除，
  MUST NOT直接转发给服务器；
  Venera source-requested resolver cache MUST由native plugin-driver host/runtime-network owner持有，
  并以`pluginId/pluginVersion/sourceKey`分区；
  单个WebView/bridge MUST只消费且不得在自身close时清空，同namespace bridge replacement SHOULD继续复用仍新鲜的resolver entry。
  该cache MUST有界、保留Cookie/请求header身份差异、不得进入Reader/Pipeline artifact所有权。
  `cache-time: long` SHOULD对齐Venera约6小时语义；普通短命中 SHOULD约5秒。
  用户显式建立新的resource generation并以`fresh:true`重新执行`onImageLoad`时，
  fresh scope内该source hook实际发起的`Network.*` resolver请求 MUST对其触达URL执行host resolver cache force-miss并随后正常写入新的origin response；
  MUST NOT清整个source namespace、MUST NOT改变普通browse/details请求的cache语义，
  也 MUST NOT因此新增或重置同一logical open的semantic retry预算。
  当前单invocation runtime已提供比same-path prevent-parallel更强的物理串行保证，不得因此新增第二scheduler或JS并发。
  Venera bridge正常完整消费Network HTTP response后 SHOULD保留原resolver client与持久连接复用机会；
  异常或request-scoped cancel MUST终止该请求与正文读取，不得为单个请求关闭共享client或重建native HTTP/DNS owner。
  Venera `onLoadFailed`属于source-owned image semantic recovery而非generic transport retry：
  public `Network.fetchBinary/http_binary` MUST继续保持通用binary API，不得因图片恢复语义被收窄；
  只有host-private image binary seam及JS image transform的完整/首段2xx body MUST先以bounded magic-prefix验证为受支持编码图片；
  non-image MUST在native-byte token注册/向Dart发布前失败，并从Venera runtime HTTP cache移除。
  host direct/rhttp对该事实 MUST显式标记`sourceMediaSemanticRejected`；
  `SourceResourceTransport` MUST由单一source-recovery owner在一次logical open内按当前config依次消费最多5个`retryResource/onLoadFailed` replacement，
  MUST NOT因为旧的`sourceMediaProtocolMismatch`总类标记直接重放原locator的full-runtime `loadResource`，
  也 MUST NOT让provider `RetryPolicy`建立第二层semantic retry。
  只有明确`sourceClientStateRequired`（redirect/Cookie/interceptor/session state无法无状态重放）才 MAY直接交还source-owned runtime client。
  Venera retained config MUST以共享retry count把streaming external retry与full-runtime恢复限制在同一5次预算内：
  replacement自己的`onLoadFailed` MAY继续产生下一config；
  达到5次、callback缺失或返回null才 MUST成为non-retryable `ErrorCode.source`。
  同一retained logical resource MUST NOT通过fresh resolve原始`onImageLoad`重置预算。
  若 semantic media rejection 后 `retryResource/onLoadFailed` 明确无 replacement plan，
  `SourceResourceTransport` MAY在同一NetLane task/同一TaskControl/同一logical open内对相同opaque locator额外执行且仅执行一次request-plan `resolveResource` re-resolution；
  该re-resolve不得重置replacement预算或成为Reader/UI retry owner，
  re-resolved plan仍semantic reject后才可发布`sourceSemanticRecoveryUnavailable=true`并交由上层stale-carrier refresh。
- Native incremental decoder MUST NOT 在完整 WebP decode、scale、composite或 frame copy期间持有 encoded byte source读锁。
  source lock临界区 MAY 刷新 demux并复制下一帧所需压缩 fragment；耗时像素工作 MUST 在锁外完成，使前台 `reserve/commit` 不被后台整帧 decode阻塞。
- App presentation MUST NOT 直接创建 `HttpClient`/`HttpURLConnection`或直接消费 source transport。
  Android隔离插件进程 MUST 在engine/driver启动前以宿主applicationContext初始化OkHttp平台资源；MUST NOT依赖主进程Startup或以扩展payload Context替代宿主资源Context。
  Venera `Network.*` 的 source runtime仍拥有Cookie、manual redirect、
  `cache-time`、`prevent-parallel`、requestId grouping与single-JS-invocation语义，
  但实际HTTP MUST由isolated plugin Dart process的reusable rhttp/reqwest resolver client执行；
  Kotlin/WebView bridge MUST NOT再持有第二HTTP client/connection pool。
  最终 media replay继续使用主流程rhttp direct transport；进程隔离允许两个owner-local client实例，但两者 MUST属于同一rhttp client family。
- host replay MUST 只用于可无状态平铺的单次 source request。
  遇到 redirect、`Set-Cookie`、未知 client wrapper、认证/session语义或成功 HTTP却非编码媒体响应时 MUST 切回 source-owned client；
  不得让独立 Dart HTTP client接管来源 Cookie/session状态。
- metadata/artwork MUST 经过 `ResourceCacheManager`；
  只有 Reader/章节 page body 与 artifact/download路径 MAY 通过明确命名的 page-body API绕过 response cache。
  插件仓库/APK/JS下载属于 control-plane，不得伪装成漫画 source response cache。
  `CachedBrowsableComicSource` MUST NOT 暴露 artwork 加载 facade。
  `loadPageBytes` 与 streaming page loader MUST 共享同一 source-resolved response path；
  full-byte fallback MUST NOT 直接调用 raw source transport。
  任何Pipeline PageStream已active的页面在transport kind暂为null/unknown时 MUST继续等待Pipeline authoritative classification，
  MUST NOT因为manifest、locator或文件名同样无法预判格式就并行启动presentation full-byte materialization；
  分类为WebP后 MUST继续streaming native output，只有明确gif/fallback等需要完整正文的分类 MAY进入该full-body路径。
  章节下载的可变资源能力 MUST 作为单一 `ChapterResourceAccess` 原子绑定，不得使用多个 setter 形成半更新状态。
- 外部 artwork MUST 通过 source-confirmed canonical comic identity 查询统一 response cache；
  命中时不得解析来源、创建 source transport 或等待插件 activation。cache miss 才可进入source loader。
  raw Mihon/插件 locator只用于 runtime调用与章节身份，不得切分 durable artwork namespace。
- Home/阅读历史中已经持久化的 HTTP(S) artwork locator MUST 始终先进入统一 `ComicSourceResourceGateway` 的 source-independent memory/durable-cache probe；
  active source/plugin 暂不可用时不得把网络 URL 交给本地文件 loader。
  durable miss 后，若是首次外部 source 发布尚未完成，gateway MUST 保持该次请求 pending，再要求来源 adapter。
- 已挂载 Home 的 chapter/SavedComic mutation MUST 通过 `HomeLibrarySession` write-through投影边界完成：
  durable store写入成功后同一次操作必须更新 session可见投影；不得先直接写 store再依赖详情页退出或 `_reloadLibrary()` 追平。
  Reader route最终 progress MUST 为 route-local状态，返回后只发布一次；不得用跨 route全局 latest-progress槽。
- Home library reload MUST NOT 用 mutation 之前捕获的旧 entries/SavedComic snapshot覆盖更新后的 write-through chapter/saved/progress投影。
- Comic artwork基础 cache schema revision MUST 只有一个 owner。
  External artwork由 `ComicSourceResourceGateway` 自动添加 `comicArtworkCacheSchemaRevision`；
  调用方 MAY 只提供 content-specific revision，MUST NOT 再传基础 schema revision形成并行 namespace。
- 初次 external runtime activation 在 session建立前发生 Binder `runtime-service-died/disconnected` 时，
  generation continuity MUST 由 Android runtime-service client拥有；最多跨一个 service generation。
  Dart/plugin activation层 MUST NOT 通过再次调用 activation实现同一恢复，业务/ABI/请求错误 MUST NOT 被重放。
- 来源确认过的同源 canonical comic identity SHOULD 持久化在 SavedComic 元数据中，供插件未激活时的书架只读归并使用；
  原始 comic/chapter request identity MUST 保持不变。
- 未访问的首页、书架、来源和杂项导航页 MUST 延迟构建；首次访问后页面状态 MAY 保留，但隐藏页面不得为首屏预先创建封面 loader 或重复发起 cover request。
- Home primary、enrichment 和可选 runtime 的状态仍 MUST 由各自 owner 管理；不得新增 App 私有正文/图片缓存或让 UI 直接调度网络。
- “更新漫画” MUST 只显示当前已在书架且存在 source-confirmed update 的漫画。章节/目录变化 MUST 由 `SavedComicRecord.sourceUpdateAt` 表示；
  confirmed同源 successor/version MUST 由 `ComicVersionRelationStore` 的持久 relation及其首次 `discoveredAt` 表示，
  并由 `HomeLibrarySession` 投影供 Home/source browser 同步消费。版本 relation MUST NOT 通过写 `sourceUpdateAt` 来伪装成章节更新。
  presentation MUST 合并两个事实源排序；阅读进度、普通 metadata刷新、仅浏览/阅读记录 MUST NOT 推进它们。
  首次入架 MUST确认当时已知的章节与版本提醒；该版本确认 MUST持久保存且不得改写relation、family heads或复用证明。普通偏好编辑 MUST保留确认，后续新章节/版本 MUST仍可提醒；跨来源迁移 MUST NOT搬运foreign版本确认。
  漫画源卡片 MAY 将 confirmed successor 投影为右上更新感叹号，点击时 MUST 可直接查看该 raw version；该提示不得把 successor伪装成已入书架。
  远程漫画缺少偏好记录时 MUST NOT 默认视为已加入书架；阅读历史 MUST 单独按 `ReadingProgress.updatedAt` 排序。

### 1.2 详情页与来源迁移
- 详情页顶部控制栏 MUST 不重复显示漫画标题；漫画标题只在详情内容区显示。
- 存在阅读进度时，详情页 MUST 提供可操作的“继续”药丸按钮；继续/阅读历史行 MUST 位于章节总数行上方，阅读历史 MUST 与按钮位于同一行并放在按钮之后，历史文字之前显示时钟图标。
  继续 MUST 通过既有`onOpenChapter` facade 打开保存的章节，不得等待无关的来源刷新。
- 远程与本地详情页 MUST 共享同一章节状态语义。章节标题前 MUST NOT 再以带圈勾/空圈表示已读；
  source-confirmed 目录更新中新增加且尚未点击进入的 chapterId MUST 以标题前圆点表示，
  第一次点击进入即消费该 durable unseen 标记，首次建立目录 baseline MUST NOT 因“刚发现目录”本身把全部章节标成新章节；
  但用户从未入书架切换为入书架时，当前 source-confirmed 目录中尚无 `ReadingProgress` 的章节 MUST 建立 unseen 标记，使新加入书架的未浏览章节立即显示圆点。
  真实 `ReadingProgress` 未到最后一页或倒数第二页时 MUST 保持正常亮度并显示“读到第 N 页”；到达最后/倒数第二页才自动进入已读弱化态并停止显示该进度文案。
  进入章节本身 MUST NOT 自动标记已读。显式右划“标记已读/恢复未读” MAY 覆盖自动完成态，但该 provenance MUST 与历史自动 read state 可区分。
  章节来源提供原始 `updatedAt` 时 MUST 优先显示来源更新时间；缺失时 MUST 显示当前持久投影可证明的本地导入/同步时间，不得用发布时间冒充更新时间。章节副标题 SHOULD 固定为单行紧凑状态：
  来源/同步图标 + `MM-DD HH:mm`、`待加载`/`N页`、以及存在进度时的历史图标 + `第N页`，各段以中点分隔；窄屏 MUST scale-down/省略而不得换成第二行。
  无标题的普通标签组 SHOULD 直接显示 chips，不得为了“标签”二字额外建立标题/展开父层。
- 详情章节行 MUST 按当前滚动视口及有界缓存范围构建；长目录或 Reader 返回后的进度更新 MUST NOT 要求一次构建、布局全部章节行。完整目录、排序、source/chapter identity、章节操作与最新进度语义 MUST 保持。
- 来源漫画第一次打开后即使已持久化为 SavedComic，后续再次打开 MUST 复用当前已持有的 comic route identity lock，
  不得在同一调用链嵌套申请相同 `sourceId + comicId` 锁而静默吞掉导航。
- 详情页 SHOULD 同时提供通用“迁移漫画源”入口与同源版本快捷入口；
  来源提供 `ComicVersionSource` 时，同源候选 MUST 使用来源自己的版本关系（Venera/E-Hentai 使用详情页 `#gnd`），不得改为标题 browse 或要求浏览器页面权限；
  gallery HTML MUST使用显式HTTP(S) source-document请求，保持来源Cookie/session与调度取消；MUST NOT作为图片进入thumbnail/transform/signature/recovery链。普通图片请求的校验与有界来源恢复 MUST保留。
  来源明确声明的 predecessor 与 successor MUST 经同一版本关系 authority 持久化为 predecessor→current 与 current→successor；MUST拒绝外源、空及自身身份，MUST保留已有发现时间和页面复用证明。MUST NOT按标题、日期或展示序号补造关系；未确认分叉 MUST仍保持 exact。
  没有该能力时 MAY 回退到来源 browse 结果。入口展示不同原生 `comicId`，不得把当前版本再次列为迁移目标。来源确认的新版关系 MUST 可持久化，使后续打开新版时也能显示旧版；
  旧版和新版都可作为同源迁移目标。
- 迁移面板 MUST 显示当前插件和当前来源，目标源 MAY 是当前来源或其他已启用来源。相同 `sourceId` 的确认版本 MUST 在同一面板提供直接“查看”和“迁移”；
  跨源标题搜索只负责发现候选，MUST NOT 建立同源关系。相同`sourceId` 下不同 `comicId` 是合法的同源版本迁移，适用于 URL/gallery locator 变化；
  目标漫画及章节身份 MUST 在任何持久写入前校验。
  通用同源版本列表 MUST在打开的面板中消费已有来源刷新结果，失败保留已确认首显；关闭面板 MUST NOT取消owner已接纳工作。关系发现时间 MUST NOT冒充来源更新日期，未知来源日期 MUST省略；候选展示 MUST使用来源Web地址，回调 MUST保持精确版本对象。
- 迁移比较 MUST 使用标题、作者、来源、章节及来源提供的普通Web地址帮助核对；没有Web地址时 MUST省略该行，MUST NOT展示或解析内部opaque identity。展示地址 MUST NOT改变plan、精确匹配、缓存identity或事务目标；用户仍 MUST明确核对目标漫画/来源及章节风险后才能确认。
- 迁移 MUST 只复制整部漫画偏好、精确章节匹配得到的阅读位置/已读状态和有证据的 artifact复用关系。目标写入成功后，同源替换 MUST 清理旧版本的漫画/章节元数据；跨源迁移 MUST保留原来源。
  确认后的事务与 durable recovery MUST 统一经 `HomeSourceMigrationTransaction` 调用 `HomeLibrarySession` 和既有 artifact owner；来源浏览/比较 UI 只适配选择与命令，不得另持迁移状态权威。
  章节比较的 `exact` confidence 指序号与归一化标题同时匹配，目标原生 `sourceId + comicId + chapterId` MUST在写入前独立校验；comparison confidence MUST NOT替换持久身份或充当media proof。sequence-only候选 MUST NOT复制进度、已读或artifact；目标已有阅读状态 MUST优先保留。
  来源专属 URL 和离线字节不得被当作可直接复制的元数据。持久化同源page mapping MUST保持compact affine offset + bounded anchor proof：
  `verifiedPredecessorPageIndexes`只记录最多首/中/末anchor的证明来源，不是逐页reuse白名单；
  accepted offset对两章重叠区整体成立，但仍必须同时绑定精确`predecessorSourceRevision/successorSourceRevision`与pageCount，
  任一结构事实变化即不得沿用。page-mapping-only 更新属于derived reuse state：
  MUST写入authoritative relation store并更新当前内存reuse authority，
  但 MUST NOT触发Home broad projection notification或为每条mapping另写Home snapshot。
  Reader恢复 MUST按当前chapter的compact mapping推导aligned exact key，
  只通过targeted batch exact-key查询筛选**已经READY**的旧缓存，并仅为source READY且target exact absent的页面注册有界临时in-memory equivalence；
  MUST NOT为未缓存页注册future/lazy equivalence，不得持久化逐页alias，也不得在Reader lookup/miss时重新调用source验证页面。
  相关source chapter manifest SHOULD按唯一chapter identity一次batch hydrate，
  MUST NOT按relation串行get、整库list或长期manifest cache；缺失manifest直接跳过。
  `lookupAuthoritative`、exact write/invalidate与显式migration materialization始终绕过equivalence，
  persistent backend保持exact-only。
- App-owned modal panel 的关闭操作 MUST 是左下角 X；确认、保存、删除等正向操作位于右侧，不得以“取消”文字按钮替代关闭 X。
- 漫画源页 MUST 使用来源自身声明的 browse section；Mihon Popular/Latest 与 Venera explore/category target 均属于来源内部分类。
  原生/Mihon/Venera 运行时类型 MUST NOT 作为内容分类行，只能以来源 chip 的视觉标识区分。
  固定大小 catalog page MUST 使用显式上一页/下一页，pager MUST 位于内容滚动尾部；切换来源、section 或外部搜索请求时 MUST 回到第一页。
  Mihon MUST 完整保留来源原生页，MUST NOT按 host limit 截断或用返回项数推算 native page；来源声明的 nextOffset MUST严格前进且仅在 hasMore=true 时合法。
  Presentation MUST使用声明的下一请求坐标，未声明时继续按 global offset + 返回项数推进；空页但有下一坐标时 MUST保留下一页入口。
  Venera `multiPartPage` MUST 以 null 页码加载完整分组集合，并按全局 offset 投影；集合耗尽 MUST 返回 hasMore=false，不得重复首片。普通页码与 loadNext 游标 MUST 保留来源合同。
- 切换漫画 source 时，Presentation MUST 在同一更新周期将 projection owner切换为目标 source；
  普通 browse 的当前 source binding 未变时，无关 source 列表增删/重排 MUST NOT重新加载或重置 section/page；聚合 source 集变化 MUST继续退休旧聚合请求。
  MUST只使用**当前 Presentation request identity**的目标精确缓存直接投影，没有精确缓存时显示目标 loading/error并按当前 section/query/filter请求加载。
  未保存目标 source的UI访问状态 MUST NOT阻止读取该精确缓存；不同请求缓存不得用于首帧。schema改变section/filter请求时 MUST退休失配投影；旧请求的迟到失败不得改写当前source投影。
  Catalog可保留目标最近 projection作为诊断/内部 cache事实，但 MUST NOT用它反向改写 UI默认 section/query/filter。
  旧 source页面不得因目标请求失败继续可见。
- 强制刷新遇到 `sourceVerificationRequired` 且存在 WebView capability 时 MAY 自动进入一次目标 source验证。
  **任何一次**手动或自动验证浏览器 handoff都 MUST 消耗该 `sourceId + request URL` 的自动 fallback机会；
  若恢复重试仍失败，后续普通刷新 MUST NOT循环打开 WebView，只保留错误诊断和手动恢复。成功 browse后 MAY 清除该 guard。
- Cloudflare WebView恢复 MUST 优先打开 typed failure中的实际 request URL而非仅打开 source homepage；
  打开浏览器 MUST NOT预先删除已有 Cookie/snapshot。WebView `onPageFinished` MUST NOT直接等价于验证完成。
  浏览器内部 SHOULD 使用比网络 classifier更保守的 challenge探针，并且 MUST 要求同站点、
  `document.readyState=complete`、WebView progress=100以及连续稳定窗口内无可见 Turnstile/challenge form/running容器/`cf-chl-*`/challenge iframe或典型验证中间态，
  才可完成当前 Cookie/UA snapshot handoff；不得把“必须生成新的 `cf_clearance`”作为唯一成功条件。
  已有同站点/同 UA snapshot在新页面成功 capture前 MUST 保留，空 Cookie capture MUST NOT破坏已有非空 handoff。
  每次导航开始 MUST撤销 capture readiness；立即取消或 Activity销毁 MUST NOT以未完成页面推进已有效 snapshot revision。
  普通页面 capture MUST属于当前加载完成的 URL；验证页面另须满足上述稳定窗口，迟到 localStorage回调 MUST NOT更新其它导航的 snapshot。
  验证探针 MUST按实际Boolean ready/challenge协议读取；无效结果 MUST保持未完成验证，不能以字符串比较阻塞加载完成的页面。
  成功回执 MUST等待当前localStorage capture与Cookie/UA一次提交；浏览器结束后的销毁及迟到回调 MUST NOT补写snapshot revision或污染下一次handoff。
  Android 13+ 系统返回 MUST接入支持的返回回调，并与旧系统共用 WebView历史/完成裁决；普通页面完成加载后的返回 MUST成功，未完成验证 MUST保持失败。Activity销毁 MUST撤销回调。
- 可见来源浏览器及登录 snapshot MUST只有`network_bridge`一个 owner；插件宿主 MUST通过共享网络边界使用它，MUST NOT保留独立登录 Activity/store。
- Cloudflare 验证浏览器 MUST 使用当前 Android WebView provider 的真实 User-Agent，MUST NOT用插件/OkHttp 的静态 UA覆盖验证 WebView。
  Cookie、localStorage 与真实 WebView UA MUST 属于同一 snapshot revision；
  Mihon runtime消费该 snapshot时必须让同站点 OkHttp请求采用同一 snapshot UA，并同步导入其 Cookie。
- WebView 验证返回后外部 runtime MAY 被重启。
  详情页与漫画源页的后续操作 MUST 按稳定 source ID重新解析当前 active adapter，MUST NOT继续调用重启前已关闭的 session。
  漫画源页 MUST 在 replacement source上重新加载 section/filter后再强制刷新，并禁止同一次恢复再次自动打开 WebView。
- `sourceVerificationRequired` MUST 只来自 typed host challenge detector：`cf-mitigated: challenge` 可直接确认；
  否则 MUST 同时满足 HTTP 403/503、Cloudflare Server header 与 `challenge-error-title`/`challenge-error-text` 交互 challenge DOM。
  `challenge-platform`/`cf-chl-*`脚本、`Just a moment`标题、
  Cloudflare header单独存在、普通 HTTP 403、timeout、解析失败和包含 Cloudflare字样的异常消息 MUST NOT被重分类。
  主网络与兼容 interceptor MUST使用同一 detector，不得使用隐藏 WebView。
- 漫画源搜索 MUST 以来源栏上方的浮动控件进入，展开后 SHOULD 提供可持久化、可删除和可清空的搜索历史。展开搜索面板 MUST 优先消费系统返回手势与垂直拖动/滚动手势，并在这些手势发生时恢复为浮动按钮。
  搜索展开和文本输入 MUST 只更新搜索子树，MUST NOT 重建 catalog 网格；
  IME inset MUST 只按键盘与浮层原始位置的实际重叠量移动搜索浮层，不得重复补偿其到底部栏的既有净空或压缩整个漫画源页，固定搜索浮层与底部来源栏 SHOULD 使用独立 repaint boundary。
  IME 开始收起时 MUST 释放输入焦点但保留面板，收起动画期间再次返回 MUST 只关闭面板且 MUST NOT 重新弹起键盘。
  普通搜索历史的嵌套滚动 MUST 同样收起面板；扩展搜索选项列表 MUST 保持可滚动选择，选项展开手柄仍执行其独立展开/收起动作。
  Mihon `getFilterList()` 返回的 Header、Separator、Select、
  Text、CheckBox、TriState、Group 与 Sort MUST 由 bridge按 Mihon基类继承关系完整投影，
  MUST NOT以插件自定义 concrete class名称猜类型或拍平 Group；空 `FilterList` 表示该 source没有筛选入口。
  用户修改 MUST 以类型化 filter-state override返回 source search调用，Text字符串与 Sort的 index/ascending不得压缩成 toggle ID。
  单次筛选弹层的草稿 MUST 在 route/IME 重建后保留；只有应用或取消才能结束本次草稿。
  “筛选” MUST 是可获得焦点的独立浏览视图；点击后即使不修改任何选项，直接应用也 MUST 以 source `FilterList` 默认状态执行 filtered browse。
  空 override MUST NOT 被解释为 ordinary Latest/Popular。
  筛选视图激活时 MUST 取消 Latest/Popular焦点，filtered request/cache identity MUST NOT继承先前 section；
  是否使用筛选 MUST 作为独立 request mode传至 Catalog/runtime。
  External plugin browse wire validator、typed request factory与 source adapter MUST 对同一参数集合保持一致；
  同一 schema版本内新增可选字段 MAY 缺省为兼容默认值，但未知字段与错误类型 MUST继续拒绝。
  标准 section Presentation顺序为“最新 → 热门”，首次进入来源时 MUST 选择当前展示顺序的第一项；
  catalog最近缓存 MUST NOT反向决定默认 section/query/filter。未来若用户自定义排序，默认项 MUST继续由同一个展示顺序 owner的第一项派生。
  筛选动作打开 filter 面板，MUST NOT 把插件 Filter伪装成 `SourceBrowseSection`，浮动搜索仅拥有 query/历史。
  browse metadata projection变化 MUST NOT 作为 artwork reload revision；
  source card direct-child State MUST 使用 canonical comic identity，raw locator或无关 page projection变化不得重置已就绪封面。
  漫画源卡片的“已入书架”视觉状态 MUST 从 Home/library canonical preference projection读取；
  已入书架封面 MUST 在左上使用明确书本/书架标志并降低亮度，source browser MUST NOT维护第二份 shelf membership；
  source-confirmed update提示与书架标志 MUST 分离显示在右上。搜索结果 MUST 使用 catalog/resource-cache 权威：
  若有**当前精确请求**缓存，Presentation MUST先显示缓存并后台刷新；只有稳定字段变化时才替换列表，不得建立页面私有结果缓存。漫画源页 MUST 支持边缘下拉达到阈值后的强制刷新；
  强制刷新 MUST 绕过 catalog cache，但 SHOULD 保留已有内容直到新结果到达。
- Mihon 插件的已安装列表和仓库列表 MUST 能按规范化语言分类；语言 SHOULD 优先使用插件声明，缺失时从插件 source metadata 推导。
  多个语言 MUST 归入多语言，无法可靠确定时归入未知语言，不得从显示名猜测。
- 搜索框退出时 MUST 关闭扩展搜索选项并在下次展开时默认收起；收起状态的悬浮搜索按钮长按 MUST 进入聚合搜索结果视图。
- 搜索框右侧 MUST 提供默认关闭的关键词锁定控件；未锁定时搜索关键词 MUST 只作用于当前提交请求，提交后 MUST 清空输入和内部 query，后续翻页、刷新、切换来源或分类 MUST 使用空 query；
  锁定时 MUST 保留关键词并允许后续浏览继续使用。
- 聚合搜索 MUST 遵循相同锁定语义；非锁定聚合提交后 MUST 关闭聚合模式、清空输入和聚合 query，但 MUST 保留已经返回的聚合结果。
  收起状态搜索按钮的点击与长按 MUST 由同一外层手势 owner 分发，长按 MUST 能进入聚合结果视图。
- 最近一次聚合结果在来源列表未变化时 MUST 保留为内存投影；切换当前来源 MUST 只退出结果页并关闭搜索框聚合模式，不得清除该投影；
  再次长按搜索按钮 MUST 直接显示该结果及其查询标题，不得显示空结果提示或重复请求。
- 详情内容区标题 MUST 打开独立的聚合搜索 route，保留原详情，并按已启用且支持搜索的 sourceId 分组；MUST NOT按插件合并来源。
  冷启动尚未激活的来源 MUST通过既有来源 lifecycle 在首帧后准备，并逐个加入当前查询；新增来源 MUST NOT重发其它来源或重置其分页，MUST NOT建立全源完成后才显示结果的屏障。
  该页 MUST 保留当前查询用于各源独立分页；每组结果/错误独立显示，慢源或失败 MUST NOT阻塞其它来源。重建 MUST NOT重发，失败只允许显式重试；旧查询/退出后的结果 MUST NOT覆盖当前投影。
  原漫画结果 MUST返回原详情，其它结果 MUST使用既有详情入口。标签点击 MUST保持该来源的原搜索目的地，包括从聚合结果进入的嵌套详情；漫画源页原聚合/关键词锁定语义不变。
  从详情进入尚未挂载的漫画源页时，初始查询命令 MUST在首个source请求前生效，MUST使用trim后的标签关键词及offset0；MUST NOT先发空关键词请求或要求再次点击才能搜索。
- Venera JM 的普通浏览链接 MUST使用漫画 album 地址；JS 更新文件地址 MUST NOT作为漫画网页基址。浏览地址修正 MUST NOT改变 canonical identity、章节缓存或资源 authority。
- 插件管理 MUST 显示安装元数据中的版本和Mihon ABI，失败态保留已知信息；“漫画源管理 → Mihon 扩展 → 设备上的 Mihon 扩展”的长包名不得挤掉版本/ABI。漫画源主列表只显示来源名称、语言及站点；UI MUST只读既有安装/扫描authority，缺失值不得从版本猜测ABI。
- Mihon APK 识别 MUST 接受 manifest 中直接字符串或字符串资源形式的 extensionLib/entry class metadata；
  多个 entry class MUST 支持逗号、分号或换行分隔。
  候选识别 MAY 使用标准 extension feature/package prefix，但加载前仍 MUST 完成 package、signer、version、ABI 与 entry class 校验。
- Android 上 Mihon 共享扩展发现 MUST 至少合并系统包枚举与已知 package name精确探测；单个 APK 识别失败 MUST 保留 package、阶段和错误信息，不得被转换为空列表。
  对已获得PackageInfo的识别失败，错误 MUST保留metadata键名、声明/解析ABI及resolved entry class文本，缺失/解析失败明确标注；
  诊断 MUST可从既有错误区复制，MUST NOT导出其它metadata值、放宽识别校验或为诊断激活来源。
  系统包可见性受限时 MUST 向用户显示诊断。Mihon 私有 App目录不属于可访问的系统扩展边界，UI MUST 引导用户从 ZIC仓库安装，而不得声称已读取该目录。
- Production external-plugin runtime MUST use an explicit bounded active-session safety ceiling large enough for mixed installed sources;
  current composition sets 32.
  The generic test/embed default MUST NOT silently become a user-visible eight-plugin limit.
- plugin host MUST NOT 把 network bridge 的内部 browser-cookie session实现列为 Mihon common runtime ABI。
  Cookie snapshot reset MUST 通过稳定网络适配器边界调用。
  Mihon `NetworkHelper` MUST 使用宿主 applicationContext读取浏览器 Cookie/UA快照；注入的插件 `Application` MUST继续使用扩展 payload Context保留资源与偏好隔离。
  Mihon 普通网页配置 MUST优先采用来源 headers声明的非空 UA，仅缺失时使用宿主 fallback；Cloudflare验证仍 MUST采用真实 WebView provider UA，MUST NOT把普通网页 UA套入验证模式。
- Mihon common runtime完整性预检中所有 `dev.zic.network.*` 动态类型 MUST 在 network bridge consumer R8规则中保留原始全限定类名和成员；
  typed `SourceVerificationRequiredException` 不得被混淆、裁剪或用错误消息字符串替代。
- app startup channel 通过类名反射挂载的 feature plugin 和 rhttp entry MUST 在 app R8规则中保留原始全限定类名及可调用成员；
  release APK 不得因 `Class.forName` 入口被混淆或裁剪而返回 `ClassNotFoundException`。
- 外部插件持久 manifest MUST 逐记录容错；一个坏记录不得清空其它已导入插件。写入 MUST 保留上一代 `.bak`；
  启动恢复 SHOULD 依次尝试主 manifest、`.bak`、残留 `.part` 和旧 `.invalid`，并允许旧 sandbox绝对 payload路径按 owned-root basename迁移。
  恢复记录仍 MUST 经过原有 payload hash、签名、ABI和 entry class检查。
- 详情漫画、章节、预览首屏/分页和评论首屏/分页 MUST 使用与漫画源页/搜索相同的 `ResourceCacheManager`，
  但 MUST 以漫画详情、预览分页、评论分页各自的稳定 response identity 分区；不得以详情页私有缓存复制 catalog cache owner。
  预览图和评论头像的编码字节 MUST 继续走统一 artwork cache，不能进入 metadata response cache。
- 进入详情页时 MUST 先投影可用热详情数据，再异步刷新主详情和可选预览/评论元数据；章节、漫画字段、预览页和评论页 MUST 分别比较，只有对应类别稳定字段变化时才替换该类别投影。
  可选请求失败 MUST 保留旧类别数据，不能清空已显示内容。强制主响应若携带内嵌首屏，MUST 更新对应分页 projection；普通主响应缓存命中不得覆盖独立分页刷新结果。
- 详情首帧 MUST 不等待下载状态检查、artifact index/page I/O、跨版本 page mapping proof 或 source request-plan；
  下载状态检查 MUST 在首帧后批量读取并合并同一路由的重复请求，版本 discovery MAY由详情/version-state在首帧后后台执行，
  但详情 MUST NOT因此主动发起page-media equivalence proof。
  普通Reader入口 MUST只恢复已有mapping并立即进入Pipeline，MUST NOT因为mapping缺失、旧proof模型或历史relation数量而同步扫描/重验同漫画其它版本。
  page mapping proof只能由显式migration、Reader启动后的有界后台准备，
  或用户显式“查看版本”产生的selected-target preparation触发，并 MUST以exact `comicId+chapterId+sourceRevision`限定范围、
  最多比较首/中/末anchor；
  selected-target preparation MUST先按`targetComicId`过滤到单一直接relation，再可按持久`intervalProbeVersion`执行一次模型迁移重验。
  普通后台对chapter/pageCount/sourceRevision仍匹配且anchor proof非空的mapping直接复用，不得用固定TTL周期性重验，也不得遍历整本其它章节。
  普通Reader的chapter metadata/version discovery MUST等首个实际页面presentation frame后才启动，
  MUST NOT在首帧前占用source request-plan/external runtime；
  显式selected-target preparation因决定首次physical acquire的canonical owner，仍 MUST在目标demand前完成。
- 详情页与漫画源页的章节 presentation key MUST 保持为 `source-chapter:${sourceId}\u0000${chapterId}`；
  `sourceId` 或 `chapterId` 任一变化 MUST 产生不同 key。已读滑动容器和下载按钮可使用各自的 `chapter-read:`/`chapter-download:` 前缀，
  但不得把标题、sequence、URL、sourceRevision 或缓存 response identity 放入章节身份 key。
- 章节行的右划 MUST 切换当前章节的已读/未读状态，不得因当前状态禁用该方向；UI MUST 先完成投影，章节补齐和已读持久化 MUST 在后台完成，不得阻塞手势。
  `chapter_read_state` MUST 能在章节尚未 hydrate 时按 `sourceId + chapterId` 独立持久化，不得通过指向章节表的外键强制先获取章节信息。
  左划 MUST 只露出最右侧垃圾桶，点击后才触发删除，不得在滑动结束时自动删除；即使章节尚未 hydrate 也必须显示该入口，只有点击垃圾桶时才允许后台补齐完整 entry。已缓存章节支持长按打开删除确认框；
  删除 MUST 同时清理章节记录、阅读进度、已读状态和离线页面，且删除实际使用完整 hydrated entry。
- 来源详情若提供预览能力，详情页 MUST 能先显示 `ComicManifest` 中已经返回的预览项，后续页 MUST 通过 `ComicPreviewSource` 独立加载；
  预览图片必须复用统一 artwork loader，不得为详情页建立专用图片缓存或等待其它章节/评论请求。
  Venera 的 `@x/y` 裁剪标识MUST 保留在预览项和绘制身份中，同时传给 `onThumbnailLoad` 的 URL MUST 去除该标识；
  去除后的原图 URI MUST 是编码字节缓存和实际请求的身份，使同一原图的不同裁剪只产生一次请求/缓存项；宿主绘制时 MUST 只显示该标识指定的原图区域。
  图片失败时 MUST 使用按资源identity 稳定生成的柔和纯色占位，不得显示破损图片图标。预览栏折叠与展开 MUST 使用同一套排版结果：折叠态只显示第一行，高度由该行实际高度决定；
  展开态继续自动消费来源分页并以 `PageView` 左右分页呈现后续行。预览项 MUST 尽量保持来源原始顺序，并在可读尺寸下放置尽可能多的图片。
  完整行 MUST 直接使用全部媒体宽度反算等面积 tile，不得以外层 Card、重复水平 padding 或扩大 item gap 消耗剩余宽度；只有稀疏末行 MAY 放大到参考完整行面积的 2.4 倍。
  实际行含横图时最多 2 项，纯竖图行最多 3 项，并受用户设置的更小上限约束。外观设置 MUST 提供详情预览每行最大数量 1–8，默认 4；该项不得混入 Reader 阅读操作设置。
  折叠与展开的图片区域 MUST 不超过屏幕高度的 90%，包括单行过高的情况；高度约束 MUST 与完整行铺满、等面积和稀疏末行上限同时成立，图片在 tile 内保持 contain。展开/收起按钮 MUST 居中且只显示箭头，不得显示“展开/收起”文字。不得拉伸、强制裁切或建立详情页专用图片缓存。
- 来源详情若提供评论能力，详情页 SHOULD 显示评论栏，并 MUST 支持分页评论次级页；评论存在回复数量和不透明 ID 时，次级页 MUST 能按原 source `subId`/回复 ID 加载回复。
  这些能力是可选的，来源未声明时不得发起插件请求。评论正文的受限 HTML MUST 将 HTTP(S) `img` 交由统一 artwork loader 作为行内图片并支持 `br`/HTML entity；
  不得把原始 `<img>` 标签显示为文本或建立 emoji 私有网络/缓存 owner。
## 2. Reader 行为
- Reader 覆盖 Home 期间，后台 library/metadata/version authority 更新 MUST 继续完成，但 MUST NOT 驱动隐藏 Home 整树 rebuild；
  返回 Home 后最多一次统一 presentation refresh。
  Reader 首个实际 presentation frame 后启动的 metadata/version refresh MUST 真正 defer 到后续 event turn，
  不得在 first-frame callback 栈内同步执行耗时准备，也不得阻塞 current page source-plan。

### 2.1 Current 与输出连续性

- current MUST 具有最高 download、decode 和 upload 优先级。
- near/far 工作不得阻塞 current；current 的 holder/播放状态也不得冻结目标页网络。
- 已有verified canonical projection的exact page MUST在physical session创建前直接解析为版本无关`PhysicalMediaId`；
  多个版本的verified overlap若映射到同一canonical coordinate，必须共享同一个physical session/writer/retry/partial owner，
  而不是在运行时枚举版本carrier。目标版本独有、未验证或冲突页 MUST保持exact-only，不能为了统一页码而强行canonical化。
  无论physical owner是canonical还是exact，当前consumer实际full/range/resume request MUST始终使用该consumer的exact `DownloadId.canonicalUri`与provider-scoped validator，
  MUST NOT把canonical anchor或其他版本URI泄漏给source transport。
- Reader网络进度 MUST直接投影resolved physical `DownloadSession`的`networkStartLength/committedLength/totalLength`；
  canonical physical owner与旧数据兼容alias都不得让Pipeline按logical exact `DownloadId`建立第二份authoritative progress session表。
  旧verified acquire alias只能作为尚未形成canonical projection/既存旧generation的兼容路径，MUST NOT覆盖direct canonical resolution；
  Trace MUST可区分`canonicalDirect`与`legacyAlias`。
- 已有 output 在 replacement 前 MUST 保持可见；缺少动画 successor 时保持当前帧并等待 producer。
- loading MUST 绑定到具体媒体区域，不得用全局 overlay 隐藏已有页面。

### 2.2 翻页

- stable ownership midpoint 默认为 50%。
- 横向目标页覆盖率达到 0.15，纵向目标页真实进入视口时，MUST 建立 transition demand。纵向 `targetCoverage` MUST 只来自真实可见的非 current page；
  只有 current 可见时 MUST 为 null，MUST NOT 从 `logicalPosition` 的 page-local fraction 通过 floor/ceil 虚构隐藏 target。
  仍在 viewport 内的 outgoing page MAY 继续作为 transition，直到其真实离屏。
- current 浅水位 bootstrap MUST 优先：
  动态 current holder depth < 3 时，speculative next/next2/previous 不得启动新的 decode refill；静态 current 一帧即满足。
  若 current 暂时在等待 source，真实已进入 viewport 的 transition MAY 独立取得一帧，避免拖动目标黑屏。
  单帧 current 的 source 暂不可执行时，已有单帧静态邻页 MUST 能由自身 source 通知继续首帧交付，不得等待滑动或其它页的 source；统一 grant 上限 MUST 保留。
- current bootstrap 建立后才恢复 next/next2/previous 多帧 staged refill；transition 不得用深水位抢占 current 的基础播放水位。
- midpoint 后新 stable page MUST 成为 current；旧 current 的已上传 output MAY 作为独立 retained/last presentation 保留并暂停播放，
  但该 retention MUST NOT占用或跳过相对 previous/next slot。相邻旧 current仍 MUST按 offset -1/+1参与 encoded/decode window；
  大跳后若已离开7/3窗口则 retention不得单独制造 download/decode demand。
- 交接不得产生 targetless demand gap、黑屏或重新创建同一 identity。

### 2.3 连续模式与控制

- 内容 MUST 等比呈现，统一使用 `height / width`；不得裁切正文，或用负位移、重叠和多套比例公式掩盖接缝。
- Reader MUST 支持沉浸、跳页、暂停、倍速、方向和布局命令；命令只通过 Reader facade 提交。
- Reader slider MUST实时跟随拖动更新thumb/page preview；
  Reader-owned scrub navigation MUST使用有界latest-wins节流（当前50ms/最多约20Hz），
  窗口内只提交最新整数页，不得为滑杆跨过的每个中间页制造navigationRevision/PageView jump/Pipeline reconcile。整数页量化 MUST由scrubber自身完成；
  长章节的Flutter `Slider` MUST NOT以`pages-1` divisions/ticks把每一页物化为RenderSlider/semantics离散刻度。
  首个目标 MAY立即推进viewport，`onChangeEnd` MUST取消pending并立即精确提交最终页、结束`Interaction.scrubbing`。
  程序化 vertical animate/jump 的 completion callback MUST只确认有效命令并读取实际ScrollMetrics，MUST NOT把真实dragging/scrolling覆盖为`Interaction.idle`；
  若pointer-up已结束Controller scrub但最终目标尚未回执，同一有效命令的completion MUST结束遗留的scrubbing并重置physical velocity baseline；no-op jump MUST NOT依赖ScrollEnd或后续滑动才能恢复stable phase。
  pointer-up flush不同最终目标时，绝对jump后 MUST立即同步physical baseline，MUST NOT让早于completion的idle observation把slider距离学习为content velocity。
  dragging/scrolling/scrubbing/idle由raw pointer、Controller输入阶段与ScrollNotification生命周期裁决，旧动画Future不得覆盖新的真实输入状态。
  scrub MUST NOT拥有current-only/visible-only资源窗口；Pipeline membership MUST继续由真实current与viewport coverage解析正常7/3工作集。
  相邻preview移动 SHOULD只产生实际窗口差集（稳定profile中通常为一项far退出/一项far进入），不得每50ms批量detach再在松手后重建。
  `Interaction.scrubbing` MAY用于方向学习抑制、UI、诊断与resource execution projection，但 MUST NOT单独改变download/decode/upload membership。
  Pipeline MUST把scrub作为transient preview而不是stable prefetch：current/transition/真实visible DownloadDemand保持同一claim并限制为local-only encoded work；同一3/7中的hidden DownloadDemand MUST只retain identity而不得新增remote source work。
  baseline DecodeDemand/UploadDemand identity MUST保持；visible/current decode MAY只请求一帧。
  既有static presentation deadline中的`next/next2/previous` MAY在scrub中以
  `localOnly + targetWatermark=1 + prepareOutput=true`提前准备一帧，但 MUST NOT因此取得remote transport authority。
  transient scrub 中 immediate `next` 与 immediate `previous` MUST作为selected target两侧对称的representation deadline，
  local preparation / one-frame decode / upload priority MUST相同；`next2` MUST保持更低。
  该对称 MUST NOT修改stable readDirection、方向学习、7/3 membership或worker concurrency。
  外层`near/far` hidden decode MUST继续允许`targetWatermark=0`表示无新执行，
  hidden upload MUST继续以`prepareOutput=false`禁止新presentation prepare而不是删除demand。
  一个external-static decode若已ended并把一帧交给presentation owner，等待其mounted/detached first-frame acknowledgement
  MUST NOT继续占据staged decode前驱；实际offscreen presentation pending仍 MUST独立有界。
  vertical viewport同时出现多个transition时，它们都属于真实foreground；实现 MUST NOT以单一transition槽覆盖其中任一页，
  且`viewportVisible=true`的vertical output prewarm MUST与current共享first-frame deadline。
  scrub结束后即使current、visible membership与role均未变化，resource control phase变化也 MUST触发重新投影；normal work MUST在同一claim/physical task上恢复，不得detach/reacquire或cancel/reopen。
  operation、coverage、direction与media-cost等事实 SHOULD投影到各自typed resource配置；MUST NOT把velocity/logicalPosition等pointer-rate连续事实压成一个跨network/decode/upload通用标量权重并形成第二scheduler。
  多consumer映射到同一physical body时，priority与provider MUST按执行资格聚合：retained/local-only claim不得提升另一个full claim的network rank，也不得为其提供remote transport authority。
  viewport acknowledge前slider仍以preview/requested page作为受控显示值，不得被旧`currentIndex`回拉。slider-selected page只可覆盖navigation identity；
  `logicalPosition` MUST始终来自同一physical vertical geometry；absolute slider scrub不是content travel，因此scrubbing observation MUST同步该physical baseline但投影`velocity=0`，MUST NOT更新travel direction。
  idle observation MUST同步physical baseline并投影`velocity=0`；初始整数页号转为viewport-center坐标、idle geometry更新MUST NOT制造content motion。真实drag/scroll MUST继续报告实测速度。
  active layout-only观察 MUST保留最近实测速度且 MUST NOT推进content motion采样时钟；有效physical sample仅随实际layout校正移位，前后pixels MUST在同一applied geometry计速。真实drag/ballistic更新 MUST按真实采样间隔计算，MUST NOT混用不同geometry的逻辑坐标或布局回调间隔。
  连续drag的source pointer时间递增时 MUST使用同域输入间隔；首个/缺失/相等时间与ballistic MUST保留Reader回调间隔，MUST NOT跨绝对时间域相减。倒退时间 MUST继续发布physical coverage/position并保留最新有效motion baseline/velocity；layout/phase MUST NOT推进baseline，scroll start/idle/scrub/controller更换或真实非source采样 MUST退休旧时间。
  raw pointer推进dragging phase时 MUST NOT再次采样当前physical position；同一输入的ScrollUpdate MUST保持真实content采样间隔，MUST NOT将phase promotion到ScrollUpdate的同步调用间隔当成运动间隔。
  新的直接运动采样 MUST退休更早的合并采样请求；原post-layout回调仍 MUST刷新coverage，MUST NOT因旧请求再次推进采样时钟。稀疏outlier诊断 MUST NOT成为policy输入。
  held scrub中的post-frame ratio收敛若再次改变vertical layout，实际应用该layout revision的frame MUST在post-frame重发physical observation；MUST NOT依赖下一pointer事件，pointer-up/input phase变化本身 MUST NOT首次暴露最终center或制造velocity。
- Reader 页码或阅读模式改变后 MUST 通过既有 progress facade enqueue `ReadingProgress`，普通翻页 MUST NOT等待 SQLite；
  persistent SQLite progress isolate尚未ready或启动失败时，enqueue MUST只在内存latest-wins缓冲并低频重试writer，
  MUST NOT在Flutter UI isolate同步SELECT/解析整章JSON/UPSERT。
  只有 lifecycle/route `flushProgressCheckpoints()` 与 close 等明确durability barrier MAY使用同步fallback。
  App lifecycle 进入 inactive/paused/detached 以及 Reader 正常 route pop 前 MUST在最终 Reader-local writer drain 之后调用 storage-owned `ReaderProgressCheckpointStore.flushProgressCheckpoints()`，
  把此前 enqueue 的最新进度提交到 durable SQLite。Home projection MUST 在 route 返回后只更新最终 progress，不得要求整库 reload。
- Reader 正常返回前 MUST 等待最终 progress writer drain **以及** checkpoint store durable flush barrier；
  flush 失败 MAY记录并允许 route退出，但不得把“已入消息队列”伪称为 durable。
  详情页等待 Reader route返回后 MUST 使用 route-local final progress更新当前投影，不得为此重读整库。
  异常进程终止只能依靠持续 checkpoint降低损失窗口，不得宣称绝对 crash-safe。
- UI 控件存在性 MUST 来自 capability，不得用静态/动画猜测下载或播放能力。
- 阅读设置中同时适用于 paged 与 continuous 的 presentation/gesture 项 MUST 按 mode 独立持久化，不能共享同一可变值；当前至少包括“连续阅读”、双击倍率/锚点、长按启用/倍率/移动/拖动边界与 zoom decode boost。只适用于单一 mode 的分页方向、纵向拼接仍保持各自单一 owner；系统栏等真正全局 UI policy 不得复制成两份。
- Reader 的点击动作配置 MUST 同样按当前实际 mode 独立持久化。九宫格必须按手势类型分层，当前 production 只消费 `singleTap`：
  单击每格可选默认行为/上一页/下一页/上一章/下一章，其中默认行为保持呼出/隐藏控制栏。
  single-tap profile MUST 同时持久化两条横向与两条纵向的归一化分隔坐标，并保证最小 cell 尺寸；实际 hit test 与可视化编辑器
  MUST 消费同一个 layout authority，不能保留固定三等分的第二套命中规则。
  Reader 内的点击区域入口 MUST 直接覆盖在当前 Reader 页面上并临时隐藏 Reader controls 与系统栏，使用户看到实际 viewport 上的命中区域。
  每次打开编辑器 MUST拥有独立 edit-session identity；异步 save completion 只有在仍属于当前同一会话时 MAY关闭/清空 overlay。cancel + reopen 后，旧保存Future MUST NOT关闭新会话或丢弃其draft。
  编辑覆层 MUST 截获输入，底层 ReaderView 不得收到拖线/点格操作；高频 divider drag draft SHOULD 保持在覆层本地状态，
  不得因每个 pointer move 重建 Reader/Pipeline，只有保存时才提交 mode settings。
  双击与长按 MUST 继续由既有缩放手势 owner 解释，不得因为增加单击九宫格而经过同一 action map；
  后续若开放双击/长按九宫格，必须作为 `gestureActions` 下独立 sibling profile 增加，不能复用或覆盖 `singleTap`。
  PageHost MUST 先完成单击/双击/长按消歧，只把最终确认的 single-tap 屏幕坐标交给 Runtime。
  单击产生的上一页/下一页 MAY 独立启用短切页动画；paged MUST 保持相邻 page-index 语义，continuous MUST 解释为相对 viewport-step 而不是图片 index，默认保留 10% 当前屏幕并滚动 90%，保留比例可按 mode 调整。viewport-step MUST直接使用 ScrollController 的目标 offset，不得伪造 pointer/drag/velocity。
  该 animation intent MUST 只附着于这一次 ReaderController page/viewport request；滑动、拖动、scrub、恢复位置与其它导航命令不得继承。scrollbar scrub/跳页 MUST继续保持绝对 page-index 语义，continuous 将 index 映射到对应图片的纵向 anchor 后直接定位，不得通过重复 viewport-step 模拟跳转。
- Reader 顶部控制栏 MUST 保留“强制重新加载当前页”的直接按钮，便于恢复与设备测试；不得把它藏入杂项菜单。
  “本漫画阅读设置” MUST 位于底部控制栏并使用阅读设置图标。右上角杂项菜单用于低频入口，当前包括全局阅读设置、点击区域设置、
  来源 WebView 打开和系统浏览器打开；Web 入口只在 App composition 能给出合法 HTTP(S) 漫画页 capability 时提供。
- 双击缩放分级与长按放大 MUST 分开设置：双击循环 1x → 一级（默认 1.5x）→ 二级（默认 2.0x）→ 1x；一级/二级倍率 MUST 以 slider 调整并在 paged/continuous 各自保存。长按放大倍率是独立值（默认 2.0x），MUST NOT 偷用双击一级/二级倍率。长按放大分页模式默认开启，连续模式默认关闭且可由 adaptive/漫画显式覆盖。
- 分页模式长按放大释放行为 MUST 可设置，默认松手复原（松手后动画回到 1x 并恢复翻页滚动）；关闭后放大保持到双击退出或页面切换。连续模式长按放大 MUST 始终保持放大，不得松手自动复位。
- 长按放大移动方式 MUST 可设置为拖动或聚焦。拖动模式内容位移 = 手指累计位移 × 拖动比率（默认 1.0，即按放大后分辨率 1:1 跟随；
  比率可设 0.25–4），聚焦模式保持手指下的内容点始终位于手指处（位移 = p·(1−s)）。拖动实现 MUST 以长按起点平移为基准应用一次累计位移，MUST NOT 逐帧重复累加导致失控。
- "最大可视"边界约束（默认开启、可设置关闭）MUST 按实际显示图片矩形计算，而非页面控件矩形：contain 留边时以图片边缘为准——缩放后图片能覆盖视口的轴，一侧越界则对侧不得越界；不能覆盖的轴保持图片居中。
  关闭后允许自由拖出视口。
- 双击放大的结果位置 MUST 可设置：居中（以视口中心为原点）、吸附（按点击半侧把图片对应边缘贴齐视口边缘，覆盖不了的轴居中）、聚焦（保持点击位置不动）。默认居中。
- 阅读设置 UI MUST 至少先区分“布局 / 界面 / 分页模式 / 连续模式”；两个 mode 内再保持双击与长按设置成组排列，双击倍率/锚点不得与长按倍率/释放/移动方式交错。相同项的 paged / continuous 控件不得绑定同一可变 preference。
- “连续阅读” MUST 在 paged 与 continuous 两个 mode 中分别设置。开启时 Reader 只在当前章首/尾的明确边界 pull 后请求上一/下一章；关闭时 MUST 只禁用该 UI traversal。逻辑previous/next MUST消费source的oldest-first顺序投影，不受详情展示顺序影响；底部下一章、顶部上一章。manifest/session MUST继续一章一个。
- 每次逻辑章节排序 MUST为每章只投影一次来源序号，比较器 MUST只比较本次投影值；同序号 MUST保持来源顺序，后续调用 MUST重新消费当前来源序号，不得复用过期目录状态。
- 同次同步Reader构建 MAY共用previous/next查询结果；后续切章与预加载 MUST重新查询当前目录，不得把presentation查询结果变为跨调用目录缓存。
- Reader邻章查询 MUST只物化当前source的canonical comic family，保留既有raw代表身份、章节catalog与entry/progress引用；本次canonical memo MUST NOT跨调用存活，后续查询 MUST读取当前source authority（ADR0381）。
- 跨章首/尾入口 MUST 在目标完整页表hydrate/source refresh后解析索引，显式initialPage MUST覆盖历史进度；next进入首端、previous进入尾端，倒置页序时使用对应反端。vertical绝对页面请求MUST经实际布局确认目标和scroll范围才完成；旧idle锚点不得覆盖请求，真实拖动接管和controller换代MUST阻止旧回执重新跳页。
- continuous 的章节边界 MUST 由 ScrollPosition 的真实 `extentBefore/extentAfter` 判断，不能用 coverage-current page 代替；
  边界后的提交距离 MUST 基于单指 pointer motion，不得依赖平台 overscroll physics；短章节同时处于首尾时 MUST按拉动方向选择上一/下一章。
  普通interior current MAY按viewport center映射，但真实min/max scroll extent MUST分别映射首/末页；
  显式slider scrub anchor存在时selected page MUST保持navigation identity，无scroll range时不得仅凭中心几何伪造另一个current。
  layout/ballistic 触发的 ScrollNotification MUST NOT 在 layout pass 中同步驱动 ValueNotifier/widget rebuild，应复用 post-frame observation owner。
- 相邻章节预加载 MUST 与上述 UI 开关解耦：无论两个 mode 的“连续阅读”是否开启，只要 Reader route 存在且有相邻章，App composition SHOULD 把现有稳定 encoded window（当前前 7 / 后 3）的**剩余水位**跨章节延伸；当前章前方/后方已经覆盖的页数必须先从 7/3 中扣除，MUST NOT 额外再加一组 7/3 demand。相邻章 demand 随当前页推进在同一 preload lease 上伸缩，并通过同一 `CompositionDownloadTransferRuntime` / `DownloadTransferOwner` / `NetLane` 建立 opportunistic demand。该 demand MUST 低于当前章正常 far demand（当前 adjacent preload priority 500、当前章 far 下限 520），MUST 继续受同一 `SpeculativeEncodedReadBudget`（默认 50MB）与 source bucket/concurrency 约束，MUST NOT 建立第二 scheduler 或 UI-owned network gate。
- 跨章预加载 MAY materialize/refresh transient source chapter capability，但 MUST NOT 仅因预加载而把未进入章节持久写入 library；用户实际跨章前 MUST flush 当前 progress checkpoint，并通过当前 `HomeLibrarySession` 确立目标章节 durable identity 后再替换 prepared Reader chapter。
- Reader 的“进入时隐藏阅读控制”只控制 Reader 上下控制与系统导航栏；系统状态栏 MUST 使用全局三态 `显示 / 隐藏 / 跟随控制栏`，默认显示。`显示/隐藏`独立于控制栏，`跟随控制栏` MUST 直接消费同一个 Reader controls visibility presentation fact，不得建立第二个可见性 owner。Android 16 / targetSdk 36 及以后不得依赖被系统忽略的旧 Flutter 非 edge-to-edge `SystemUiMode` 隐藏状态栏，Android 实现 MUST 由 Reader platform owner 使用 `WindowInsetsController` show/hide status/navigation bars。Reader exit MUST 恢复系统栏；App resume 和控制栏显隐变化 MUST 重新投影当前 policy。
- 连续模式的缩放（双击分级、捏合与长按放大）MUST 作用于整条页面序列的统一变换：所有可见页一起缩放，接缝不得分裂。放大是视口空间的视觉层：
  列表滚动 MUST 保持可用（可在放大状态下继续滚动切页），跳页/滑动不得自动复位缩放；仅方向切换/换章节等结构性变更复位。
- 连续模式放大后双指捏合松开 MUST 保持结果倍率与偏移，不得因倍率低于阈值自动弹回 1x。已在放大态时长按 MUST NOT 跳变倍率，仅按移动方式调整水平偏移并在松手后锁定。
- 双击的第二下按住超过长按阈值时 MUST 触发"固定水平偏移锁定"：放大态保持当前倍率并固定整条 strip 的水平偏移，按住期间 MUST 禁用水平方向拖动；从 1x 开始时 MAY 进入一级倍率。
  松手保持倍率与偏移，且 MUST NOT 触发单击呼出控制栏。锁定态再次普通双击 MUST 仅退出锁定并保持当前倍率；解锁后的普通双击才继续离散阶段循环。
  双击配对 MUST 使用屏幕坐标判定（strip 变换会使局部坐标在动画期间漂移），且 MUST 用离散阶段索引推进 1x → 一级 → 二级 → 1x：
  快速连续双击 MUST 单调步进，MUST NOT 因动画中间值回退到更小倍率。未锁定时普通单指水平滑动 MUST 平移整条 strip；锁定时 MUST NOT 改变偏移，从而以固定偏移从视觉上整体裁切漫画边缘；
  双击第二下按住期间 MUST 独占指针：禁用垂直滚动切页，松手恢复滚动并锁定倍率与偏移，且 MUST NOT 触发单击呼出控制栏。
  双击/再放大换级时 MUST 以"保持锚点内容不动"计算目标偏移（offset' = f − s'·((f−o)/s)，除以当前倍率；
  一级进入时 s=1 退化为既有公式），二级及以上的偏移 MUST NOT 按一级偏移基数计算。分页和 strip 的二级换级都 MUST 按当前倍率换算锚点并使用实际缩放图片矩形进行边界钳制；
  缩放动画 MUST 直接向解析后的目标帧插值且逐帧按当前倍率钳制偏移，MUST NOT 先按旧偏移播放再二次修正产生回跳或过程越界。
  strip 处于放大态时延迟比例提交（provisional→measured）MUST 冻结，不得在放大镜下改变内容尺寸；回到 1x 后立即落盘。
  缩放倍率变化经 `onZoomScaleChanged` 投影给解码提升，仅为可视区域提高解码分辨率且不超过原图。

### 2.4 页面几何、输出与预热合同

纵向Reader的异步尺寸更新 MUST 在finger-owned dragging/scrolling/settling期间冻结所有会改变当前viewport前缀的sliver geometry；
idle采用这类新geometry时 MUST 以layout-time correction原子维持top-pixel连续；准备到应用之间的新drag MUST保留prefix补偿并叠加真实motion，重复layout MUST幂等，诊断读取 MUST NOT固定补偿目标，已应用补偿 MUST在frame末退休。
idle已位于可滚动章节真实尾端时，ratio/viewport/DPR变化 MUST以同一layout-time correction保持新ScrollMetrics的maxScrollExtent，包含系统insets，MUST NOT从页面extent总和推算；显式slider center anchor优先，首端/interior及无独立尾端的短章仍保持原top anchor。
implicit insets单独改变scroll范围时，idle末页Controller MUST保持旧真实尾端；pending page/viewport命令、controller换代、slider center与真实motion MUST优先，不得用旧尾端覆盖新入口。
物理pixels观测、scene诊断与top-anchor准备 MUST使用同一ListView布局捕获的geometry；帧末新ratio不得提前解释旧pixels。多次header更新 MUST从同一物理anchor累计校正，不得发布中间页码或伪造速度，见ADR0361。
首尾页导航位置 MUST保持真实ScrollMetrics边界语义；速度 MUST由同一已布局geometry的连续视口中心坐标采样，首尾页语义覆盖 MUST NOT被当作运动位移。不得以velocity clamp替代物理采样。
slider `Interaction.scrubbing` 是绝对page-index导航，不属于上述content-drag冻结。
slider-selected整数页 MUST在整个scrub transaction内保持显式center anchor；所有已知`index <= selected`的authoritative source ratio MUST在pointer-up前提交，
因为任一prefix extent都会改变该绝对目标的物理offset。已真实visible的post-anchor ratio也 MUST立即采用并重发coverage。
若layout新暴露的相邻页ratio已经在pending中，后续held-scrub layout MUST继续消费，不得等待另一次dimensions event。
pointer-up只结束input phase；selected-page center MUST继续锚定放手后才到达的ratio，pending map暂时为空 MUST NOT作为尺寸收敛证明。
纵向Reader的内部页入口（包括历史恢复和Controller更换）MUST保留其绝对page center锚点，物理offset按真实ScrollMetrics范围约束，直到真实内容运动或新导航接管；布局回执 MUST NOT证明后续尺寸已收敛。首/末页入口保持显式边界对齐。
idle viewport、DPR及stitch变化 MUST在同一次layout以新geometry保留既有绝对page center；DPR替换ScrollPosition后的首个dimension pass MUST仍应用pending校正及真实首尾范围，不得降级为普通top anchor或以jumpTo伪造内容运动。
真实content motion、新的page/viewport命令、direction或Controller更换 MUST退休该既有导航锚点；
锚点寿命 MUST NOT等待下载/首帧、延长scrubbing或改变Pipeline执行资格。
该规则只修正absolute navigation geometry；新暴露页仍只获得既有transientPreview资格，MUST NOT扩大hidden decode/upload窗口。
DecodeSession首个成功frame MAY触发尺寸事实提前解析，但Reader页面几何的最终authority MUST是source canvas而非decoded raster；
Pipeline只读`PipelinePageDimensionsFeed` MUST携带dimension basis并优先`PageAsset`/WebP source canvas，
decoded raster仅可作为provisional fallback且 MUST NOT覆盖已知source canvas。
VP8X/VP8/VP8L source canvas解析 MUST只依赖其固定header，不得等待整个compressed image chunk；
presentation output/surface raster MUST NOT经UI尺寸回调成为Reader source geometry。
`DownloadSession` MUST持有generation-local source-metadata prefix并可投影`sourceCanvasWidth/sourceCanvasHeight`；
该prefix不得复制正文，且Pipeline/PageStream MUST从physical ingress读取source metadata，
MUST NOT直接从可能为空的session `Artifact`猜测resident body。设备诊断命中该路径时source MUST记录为`physical-ingress-source-canvas`。
Resident replay MUST区分未绑定`DownloadResidentReplaySource(session,endExclusive)`与physical-generation bound `DownloadResidentReplayChunks(endExclusive)`；
`DownloadSession`只能消费bound capability，Pipeline/registry只能在当前physical session解析后绑定一次。
cache/local-source backend选择 MUST由`CompositionDownloadTransferRuntime`拥有，
Pipeline MUST NOT自行实现resident replay backend routing。
该feed MUST NOT暴露Flutter `ValueNotifier`/`ValueListenable`，
consumer attach MUST可重放retained dimension facts，publish/clear MUST保持Pipeline-private；
Pipeline output/progress core同样 MUST NOT直接依赖`WidgetsBinding`/`SchedulerBinding`或Flutter notifier；
visual frame boundary MUST通过`PipelineFrameScheduler`由presentation adapter注入，
transfer progress MUST通过只读`PipelineTransferProgressFeed`投影。
forward方向严格位于真实visible tail之后的future source ratio MAY提前采用；reverse incoming prefix MAY以提交前top-pixel anchor在同一次layout原子补偿。真实visible页的新ratio通常 MUST等待idle，slider-visible采用保持既有例外。
不得恢复dev.286 visual extent/OverflowBox workaround，也不得以扩大decode previous1/next2掩盖source geometry authority错误。
vertical active期间far/near hidden native static upload MUST继续defer；既有2/1 deadline中的next/next2/previous一帧 MAY提前UploadLane/present且 MUST retain，保持encoded7/3与唯一调度owner。
生产Reader MUST默认保留native decode与Android SurfaceProducer output；
dev.311 Flutter `ui.Image/RawImage`默认实验已被设备证据否证，不得继续作为生产默认。
该路径的UploadDemand只准备/持有output，真正RGBA Surface copy发生在presentation；
同一lease已resident的具体OutputFrame再次present必须零copy复用并记录`platformResident`，不得重复platform blit/schedule。
frame identity变化、resize/release使该复用失效；SurfaceProducer重建仍由platform redraw负责。
`PipelinePageSurface.presentationIdentity` MUST稳定标识底层 presentation target，而不是每个动画帧包装对象；
同一 Android lease 的动画帧更新不得触发 Reader 页面子树重建或重复 PlaybackGate，
UI/PageView frame MUST优先，surface/lease/fallback/尺寸/错误变化仍 MUST立即更新视觉 projection。

前台 current Animated WebP MAY 由 Pipeline runtime 依据实际 native decode throughput 相对该帧 duration 的持续超预算证据降低 DecodeTarget raster；
该 governor MUST 为 Reader-session 瞬时状态，MUST NOT读取Android power-save、
cpuset、CPU affinity或Reader UI timing作为触发authority。
降档必须有连续样本hysteresis，moderate lower raster若仍连续无法满足slow budget MAY继续升级到severe；
恢复full必须要求更严格的持续fast证据且只能在后续page boundary执行，当前页被authoritative确认static时可直接恢复。
降档状态 MAY跨animated/尚未分类相邻页保留，但Reader重新attach MUST从调用方base DecodeTarget重新开始。
该机制只能改变decoded/presentation raster，MUST NOT改变source-canvas geometry、
encoded/download 3/7、DecodeDemand staged waterline、UploadDemand资格、network/cache/durable authority或用户播放状态；
后台lifecycle仍必须暂停媒体链，禁止用降raster代替暂停。
`PipelinePageSurface.presentationIdentity` MUST以 opaque token 稳定标识底层 presentation target，
不得暴露 lease/image 或每个动画帧包装对象；同一 Android lease 的动画帧更新不得触发 Reader 页面子树重建或重复 PlaybackGate，
已有 output 的 transient `uploading` 与 present 完成通知 MUST NOT 重新广播到 PlaybackGate；
同一 presentation target 的旧 claim 在平台 copy 完成后 MUST 立即释放，
只有真实 surface/lease/fallback 替换才通过 `PipelineFrameScheduler` 合并到安全 frame；
若 successor 在 Flutter persistent callbacks 或下一帧已排队期间到达，Pipeline MUST只合并最新帧并在该 frame 后提交，首帧仍 MUST立即确认；
UI/PageView frame MUST优先，surface/lease/fallback/尺寸/错误变化仍 MUST立即更新视觉 projection。
Reader WebP texture viewport MUST 使用 `FilterQuality.low`，避免高分辨率横向 gallery 首次合成时同步生成 mipmap。
横向 gallery 中，physical ingress 已确认 `ContentKind.webp` 但 decoder 尚未确认 static/animated 的页面 MUST NOT 因 `animatedHint=false` 或 visible-static 推断获得 speculative static UploadDemand；
浅层可见 previous/next 继续保留既有 decode/encoded work，只有既有 role 真正成为 current/transition（paged transition coverage 0.15）时才取得对应 primary UploadDemand，
decoder 后续确认 `animated=false` 后 MAY恢复 static warming。static-warm MUST只消费正向静态证据：
decoder authoritative `animated=false`、JPEG/PNG/AVIF等明确静态container hint/后缀，
或同章至少两页authoritative static且尚无authoritative animation时的既有chapter-level unresolved-static inference。
默认 `animatedHint=false` MUST NOT作为静态证明；opaque unknown、WebP/GIF hint与`.webp` URI在未分类前均保持unresolved。
chapter-level inference MAY给尚未被page-local runtime sniff的未分类页一帧warming；
一旦该页physical ingress确认`ContentKind.webp`，它 MUST等待自身decoder classification。
横向 gallery 的 current/next/transition role 计划 MAY 在 PageView host 挂载前建立有界 detached output；
该 projection MUST 不等待 upload ready、WebP sniff 或 decode classification，upload ready 后只预呈现首帧；
其中 paged（LTR/RTL）animated/unresolved 的真实活动手势目标 MUST 在既有 DecodeDemand 内获得一个且仅一个 first-frame UploadDemand（当前priority 820）：
稳定方向下的 `next` 保持原语义；若 dragging/scrolling/settling 的 `targetCoverage.pageIndex` 指向相邻 `previous`，
即使 3/7 稳定方向尚未翻转，该实际目标 MAY 暂时取得同一 demand。Coordinator MUST在prepare/present前先冻结该UploadSession的viewport playback，
使detached output可将frame0预呈现到exact-size platform lease但 MUST NOT启动隐藏successor播放；
目标→transition/current MUST恢复同一UploadSession/output并复用已resident首帧。
该presentation projection MUST在plan sync与PageView host attach期间继续绑定同一DecodeId，只有离开允许的presentation role后才可解绑；
该边界 MUST NOT改变 3/7 方向状态、扩大decode/download窗口/水位或传播到next2，
idle `previous` MUST NOT因此获得UploadDemand，vertical Reader MUST NOT获得hidden animated preupload；
manifest、已知 physical content kind 或明显非-WebP URI 后缀已确认的页面 MUST NOT 建立无用 native output；
current 且无 listener 或尚无 resident surface 时 MUST 立即预热，
next/transition 在 Flutter frame 已提交或排队时 MUST 延后到 scheduler idle task，
动画/触摸回调未清空前不得启动 platform create，仍继续解码且不得提交隐藏 successor，host attach 后 MUST 立即追上最新帧；
Android texture lease prewarm MUST 使用 source canvas 按 DecodeTarget 等比 fit 后的实际 decoded raster 尺寸，
DownloadSession 解析出 WebP 固定前缀 source canvas 后 Pipeline MUST 尽早为 current/next/transition 请求该精确尺寸；
同一 raster 尺寸的 deferred request MUST 按 current > transition > next 优先级每个 idle task 最多启动一个 platform create，
idle+pending 总量 MUST 受全局有界池限制；decoded frame 到达后的尺寸仅作兜底，失败请求 MUST 可重试；
该边界不得改变 playback/freeze 语义。vertical Reader MUST不启用横排特有的decode-only animated-next lease prewarm；但对已经拥有real UploadDemand的static `current/transition/next/next2/previous`，MUST在host mount前预绑定detached output consumer，使ready output可立即claim/present；`far/near`在active期间仍不得因此建立detached native presentation。
SurfaceProducer exact-size prewarm MUST materialize `SurfaceProducer.getSurface()` on the serialized blit lane before the lease enters the idle pool，
并 MAY 通过 acceleration-only native prepare 预配置 exact decoded raster 的 RGBA geometry；
prepare 失败只能使该 speculative prewarm 失败，MUST NOT 成为真实 upload/present 的 correctness authority。
首个真实 native blit MUST 独立复核 ANativeWindow geometry，并在失配或 lock recovery 时自行配置。
prewarm MUST NOT call `scheduleFrame()` or alter playback/freeze/resume state.
Same-size prewarm requests MUST coalesce;
if an authoritative upload acquire for that raster is already in flight,
the prewarm MUST observe that acquire rather than create a second producer.
When the bounded idle pool is full, a new exact-size request MAY evict only the oldest idle lease;
pending creates MUST remain bounded and MUST NOT be replaced by an unbounded UI-owned queue.纵向 page shell composition 的 steady-state `cacheExtent` SHOULD 固定为 2 个 viewport 高度；
首次布局 MAY 使用一次有界 6 屏组成以准备初始相邻 page host，并在首个 scroll end 后收回到 2 屏。
该值只影响 Flutter sliver 组成，不得扩大 Reader 的 encoded/decode/upload/texture 需求窗口；
不得在 idle post-frame 回调中逐步扩张 cache window。可见静态页的输出保留由 `UploadDemand.retainOutput` 明确表达，不得依赖页面 role 推断；
native decoded/upload output 的实际驻留由 `FrameBudgeter` 保护。
Reader external-static 的 FileImage/ResizeImage/MemoryImage raster residency MUST由 App composition 的 `PipelinePresentationRasterCache` 统一拥有；
该 owner MUST复用同一个 `ImageStreamCompleter`/keepAlive handle，不得复制 RGBA，并 MUST通过 `ResourceCacheCoordinator.presentationRasters` 参加统一 inspect/trim/clear。
mounted managed-static consumer MUST绕过 Flutter `Image` 的 `ScrollAwareImageProvider` 二次滚动调度，并且不得通过 `TickerMode`/ImageStream listener形成第二个offscreen completer keepAlive；
consumer只可持有当前 `ImageInfo`，Pipeline撤销external presentation permission时 MUST立即释放该引用。
Flutter generic `ImageCache` 仍可服务非 Reader 图片和 provider decode backend，但其可用 bytes/entries MUST扣除 managed Reader raster 的精确占用，
两者共享当前100MiB/1000-entry presentation 总额度，MUST NOT成为两套独立 LRU authority。
当统一owner因预算回收speculative raster后，MUST由该owner同时拒绝同identity的speculative re-admission，直到claim提升为deadline/protected；Pipeline MUST NOT另存far-eviction tombstone或被动revalidation状态。
mounted与detached消费者 MUST共享该准入事实；已挂载的屏外PageHost listener MUST NOT绕过owner denial重新申请first-frame grant。
`clearPresentationRasters()` / memory pressure MUST只清residency而保留现有demand claim；被clear的speculative identity MUST进入同一owner-side admission denial，deadline/protected claim MAY按当前需求恢复。

## 3. Pipeline 与角色合同

`ReaderObs` MUST 表达 stable page、fractional position、current/target coverage、viewport/physical target、阅读方向、
interaction/zoom 和单调 revision。

横向 paged 与纵向 continuous 的 fractional observation 在 current/stable、
target page、target transition visibility bucket、visible page membership、
playback phase 和 interaction control phase 均未变化时，PipelineReaderSession MUST 在 enqueue 边界丢弃 control no-op；
playback phase 与 transition threshold 的离散边界仍 MUST 提交。

默认资源策略：

- encoded逻辑/retention与network-demand window：前 7 / 后 3；animated/未决WebP MUST同样保留完整3/7 demand。
  opaque plugin URI在manifest无WebP hint时，runtime ingress sniff到`ContentKind.webp` MAY作为transport-cost evidence启用既有bounded body flow，
  MUST NOT冒充animation truth。动画 MAY附加physical-task frame credit：
  current/可见transition unlimited，next/next2/previous默认5/3/2，其余远端默认1；
  该credit只随**同一页面自己的role**变化，较近页的download/decode速度、holder depth或decode staged waterline MUST NOT提高、
  降低或阻塞另一页的encoded transfer。ANMF structural count与DecodeSession-owned playable-prefix floor必须同时满足才 MAY park。
  dev.268起 flow/demand park MUST保留同一ByteResponse/StreamIterator与physical task；
  DownloadJob只释放NetLane body-read permit，不得通过`DownloadFlowSuspended`、
  `iterator.cancel()`、Range capability或Reader角色把“水位满足”解释成response结束。
  NetLane normal5 + current reserved1 MUST分别约束network/source transport lease与body-read permit；
  live source response park只释放body permit，MUST继续占transport lease，
  因此`running`可因local artifact/non-network physical work高于5，但live source/socket不得无界增长。
  不得存在独立`maxInactiveParkedResponses`容量owner；
  transport lease饱和时NetLane MUST先优先回收`demanded=false` inactive parked lease，
  并以`downloadEvicted(evictionReason=inactive-transport-lease-reclaim)`记录；
  若只有仍demanded的parked response占用lease，则更高rank incoming MAY按统一`NetPolicyRank`+preemption margin回收最低rank retained response，
  并以`downloadEvicted(evictionReason=ranked-transport-lease-reclaim)`记录。
  两者都 MUST NOT伪装成`downloadPreempted`或占用body-read preemption transaction；
  低rank/equal-rank demand不得仅因slot pressure破坏已投入较高restart-cost的live response。
  retention eviction即使正在等待旧response退出，也 MUST NOT阻塞current-ranked handoff；
  current live-response reacquire MUST先于对另一blocked high-priority pending task发起新的destructive admission preemption。
  Reader profile MUST NOT按3/7推导socket容量。
  artifact-cache durable local body同时释放network transport lease与body-read permit；
  `consumerPacing`不保证native upstream byte backpressure，因此 live source response MUST由transport lease有界；
  不得恢复100ms pseudo-drain。任一resume/probe/full-body attempt在启动时authoritative partial边界前 MUST绕过frame credit。
  physical structural frame proof MUST由DownloadSession generation owner保存；
  真实eviction后若positive target已由partial+playable floor满足则不得无意义重开，target0/current或更高target才继续网络。
  static/non-WebP、artifact-cache/resident仍不得被WebP frame credit阻塞；
- Reader后台encoded预读取 MUST受application/composition共享的实际读取预算约束：
  默认50MiB并可配置，配置只改变下一read quantum的pause threshold，MUST NOT改变3/7 DownloadDemand、
  frame credit、Decode/Upload eligibility或NetLane task admission。
  priority<900的opportunistic网络source growth与resident/local replay实际读取字节计入预算；
  current/可见transition(priority>=900)和显式required completion MUST绕过。
  达到预算的live source task MUST释放body-read permit并保留同一response/transport lease/partial，条件解除后原地resume；
  resident bound replay MUST将大logical range拆为最多256KiB physical provider quantum，并在quantum之间响应取消。
  新Reader-local WebP projection若已有hot partial或可range-replay durable resident body作为physical byte authority，
  其首次0..256KiB decoder bootstrap probe MUST NOT仅因较早speculative accounts已占满预算而无限等待；
  该首个probe MAY跨threshold至多一个256KiB quantum，但读取完成后仍 MUST计入同一budget，
  第二个及后续quantum在priority<900时 MUST重新服从普通budget gate。
  该例外 MUST NOT授权新的network source growth、不得改变3/7/priority/DecodeDemand/UploadDemand，
  并 MUST继续经composition唯一`ArtifactCacheReadScheduler`。
  provider已进入的一次不可取消read MAY完成，任意transport单个已交付chunk MAY造成一个chunk的阈值超调，
  因此该值是bounded pause threshold而非对wire bytes的虚假绝对硬截断。
  该设置 MUST与`cacheLimitMb`分离，legacy `animatedWebpPrefetchBudgetMiB` MUST继续忽略；
- 深度 animated/unresolved decode 角色：前 2 / 后 1；
  positive static 另可在完整3/7 encoded window内建立 `targetWatermark=1` 的one-frame intent，但不得借此获得多帧深水位；
- 动态 holder 最大水位为 current/next/next2/previous：7 / 5 / 3 / 2；
- upload primary：current、transition；
  上一 current可通过独立 retained-output overlay获得 `last` upload demand，且不得改变其相对 download/decode role；
- lane normal concurrency：network 5、decode 3、upload 2；
  network/decode/upload 各 MUST 保留 1 个仅 current(priority 1000) 可用的 bounded handoff slot，
  transition(priority 900)不得占用；
- source bucket：local 2、remote 5。

Policy MUST 只输出 demand/keep，不得创建 transport、artifact、cursor 或 texture。静态一帧满足；
当exact static DecodeSession已经满足且没有pending source revision时，
role/priority-only DecodeDemand migration MUST NOT重新enqueue DecodeLane；
当同一UploadSession保有ready authoritative static output、
无successor/failure/in-flight prepare时，UploadDemand role/revision migration MAY原位adopt该output且 MUST NOT重新enqueue UploadLane。
动画、缺帧、source revision/generation变化与failure recovery仍 MUST走完整media work路径。
positive static evidence MAY在完整3/7 encoded window内建立 `targetWatermark=1` 的DecodeDemand/UploadDemand；
这些只是one-frame intent，`StagedDecodeRefillPolicy` MUST按priority一次只释放一个尚未满足的speculative static presentation，
不得恢复page-count/estimated-output-byte admission gate。
fallback/GIF在Reader-local ingress权威分类后 MUST把native decode分支终结为external-presentation requirement；
UI MUST只在Pipeline投影该exact external request后启动Flutter decode/presentation，
`transferActive`、mounted host或文件存在本身均不得成为load资格。
external presentation 的“已启动”状态 MUST以非空 `externalPresentationCacheIdentity` 的 exact generation 为键，
而 MUST NOT以 `LocalImagePlayer`/widget 生命周期为键。
Pipeline external presentation request MUST携带 typed presentation fit；`contain` MUST按 viewport physical width/height 双轴导出 raster key，
纵向 stitched `fitWidth` MUST只按 physical width 约束，source aspect 派生的 long-page height MUST NOT被 viewport height 截断。
mounted `MediaRasterImage` 与 detached prewarmer MUST共享同一 raster-key policy，并消费同一个 composition-owned `PipelinePresentationRasterCache` entry。
Pipeline cache authority、detached prewarm与mounted UI MUST由同一composition-bound `PipelineStaticPresentation`关联；展示端MUST NOT固定选择process-global实例。替换authority后的首帧、resident复用、eviction/regrant与claim清理MUST仍归同一owner。
同一owner的capability重建MUST保留mounted attempt；owner更换MUST复用既有loadEpoch/token fence退休旧绑定，MUST NOT新增cache、队列、timer或扩大预算；capability不复制residency/claim/LRU状态（ADR0351）。
Pipeline MUST只投影 residency claim：`far/detached` 为 speculative，`next2/next/previous/near/last` 为 deadline，真实 viewport/current/transition 为 protected。
cache owner MUST只在预算压力下回收 speculative entry，并在真实回收时主动向 Pipeline 发 exact invalidation；Pipeline MUST NOT通过 `obtainCacheStatus`/`statusForKey` 轮询 Flutter residency，也 MUST NOT把角色提升实现成被动 revalidation。
`externalPresentationSatisfied` MUST只代表统一 cache owner 当前仍持有该 raster；收到 owner eviction 后 MUST撤销该 proof，让既有 staged refill 在需求仍有效时补帧。
cache eviction 与 DecodeDemand/UploadDemand demand gap 都 MUST只改变 residency/claim，不得旋转 `externalPresentationCacheIdentity`；
source/recovery/force-reload 或 fit 变化才 MAY旋转该 identity。Reader route retention/reentry MUST NOT被视为 presentation generation 变化：
retained `PipelineReaderSession` MAY释放 page host/PageOutput/native decode/upload working set并释放 presentation claim，
但 MUST保留 composition-owned presentation cache identity；若 raster 仍resident，mounted consumer MUST在任何encoded file/bytes reopen之前直接复用同一 completer/key。
`PipelineReaderSession.dispose()` MUST释放所有presentation claim并注销cache invalidation listener，direct dispose与retention不得存在两套清理语义。
fit 变化 MUST只失效/旋转 presentation cache generation 与 external first-frame proof，
并经既有 staged refill 重新授予，MUST NOT改变 DecodeId/source/download identity 或产生第二 scheduling authority；
同一 mounted widget 与同一 PageOutput 在 DecodeId/source generation rebind 后收到不同 opaque identity 时 MUST重新取得一次 load 资格，
且每个 identity 至多消费一次。旧 identity 已启动、完成或失败 MUST NOT压制新 generation grant；
该 adapter 状态 MUST NOT升级成 Reader retry、transport、cache 或 scheduling authority。
每次artifact-cache presentation bytes/file read MUST携带同一次读取的不可变`storageId + generation` authority；自动decode failure recovery MUST回传该exact authority，MUST NOT按page查询最近generation。manual force reload无旧read token时 MAY让cache owner解析当前authority。
`LocalImagePlayer`取得presentation file lease后 MUST立即进入release保护；取消/替换发生在await期间时late lease仍 MUST释放。automatic recovery/retry结果 MUST绑定启动时load generation/token，旧结果不得重启新图片。
文件presentation的release MUST等已启动的file/buffer/codec Future实际退出才关闭descriptor；取消listener MUST NOT提前关闭仍被共享pending completer读取的fd。
mounted teardown MAY异步请求release，detached prewarm MUST等待该物理release完成；已release的provider MUST NOT启动新读取，失败路径仍 MUST完成释放。缓存key/residency/调度权威保持不变（ADR0380）。
GIF codec `getNextFrame()` MUST由单一串行fetch拥有；pause/resume MUST NOT在旧fetch未完成时发起第二fetch，loading→ready MUST NOT改变媒体子树identity或重建codec。
实际首帧回报后才可满足该watermark并释放下一张speculative fallback，新的current/transition MAY抢占等待中的后台request。
真实 viewport 可见静态页 MAY 获得一帧输出，且不得重新引入 `PageRole.visible`。
纵排 dragging/scrolling/settling 期间，非 current/transition、既不在真实 viewport 也不在既有2/1 deadline窗口的 far/near native speculative static page MUST defer UploadDemand；已就绪local-static与已分类external-static保留现有例外。
既有2/1中的 next/next2/previous一帧 MAY提前UploadLane/present且 MUST retain；DecodeDemand MUST保持既有窗口语义，idle后 MAY恢复stable-role static warming。

## 4. 网络调度

- composition-owned `NetLane` MUST 是页面网络的唯一调度权威。
  Reader 首个真实 presentation frame 后的 metadata/version/reuse warmup MUST 作为 application `NetLane` 的后台任务提交（当前 rank=100），
  不得由 first-frame callback 直接启动无 `TaskControl` 的 source invocation，也不得新增 Reader 私有 timer/lane 来规避 source HOL。
  该 scheduler-owned `TaskControl` MUST 贯穿 comic/chapter metadata、
  version discovery、version-reuse warmup 以及其中的 verified-reuse request-plan probe；
  decorator/runtime adapter MUST透传，不得在中途退回 generic source API。
  带 control 的 warmup MUST NOT join 一个未绑定该 control 的 generic coalesced Future。
  foreground page-plan MUST可依既有 rank/preemption 规则让该后台任务退出；
  若底层 Venera invocation 已开始，唯一 runtime permit 仍 MUST 等旧 invocation 物理结束后才可转交。
- current SHOULD 使用 priority 1000；network/decode/upload可各有一个current-only bounded handoff。
  network `NetLane`在normal 5槽满时 MUST先用唯一reserved槽直接admit current，MUST NOT仅为借该槽先取消running task；
  只有normal+reserved均饱和且current仍blocked时 MAY按统一effective rank与40分margin preempt。
  priority 780/800/820/900的normal work MUST NOT主动取消仍有consumer demand的active task来抢普通槽；
  只有`demanded=false`的already-admitted inactive task MAY在真实容量阻塞时由NetLane统一reclaim。
  破坏性network preemption MUST具有NetLane-owned incoming candidate stability：Reader当前100ms；
  candidate未连续保持high-priority blocked至窗口结束前 MUST NOT cancel active victim，
  但free/reserved slot admission MUST仍立即发生。
  每个NetLane MUST最多允许一个scheduler-preemption victim处于cancelled但尚未物理退出状态；
  该victim退出前其他blocked current MUST只排队/更新rank，不得继续cancel更多active transport。
  scheduler/consumer typed cancellation MUST只结束transport attempt；
  若writer已有authoritative bytes，DownloadJob MUST先flush再pause，
  DownloadSession MUST回`idle/failure=null`并保持committedLength/Ingress/epoch，
  MUST NOT写成`DownloadState.failed / Failure(cancelled)`。
  already-admitted task在logical claim归零后 MUST迁移rank0而不是由Reader/session直接cancel；
  queued且从未admit的undemanded work MAY直接移除。普通可Range-resume的committed partial不得仅因字节较多自动变成不可抢占sunk cost；
  victim经济性仍由统一`NetPolicyRank`的真实不可恢复restart cost决定。consumer-bound transport真实dispose、任务错误、显式用户取消仍可硬终止。
- 显式 chapter manual-download MAY在一个 command 内同时维持多个 exact page demand，但该编排 MUST复用同一个 composition `DownloadTransferConsumer` 与唯一 `NetLane`，不得创建 page pool/network executor。当前 chapter window 为2，且其 `downloadBucketLimitFor` MUST为2或更小；二者不得独立漂移。window MUST按 page operation 的完整 settle 滑动补位：一个 page 的 promotion、durable persist/structured materialization完成后即可移除其 demand并 admission 下一页，不得等待整批 page 全部结束。若任一已入场 page 首先失败，chapter owner MUST停止新 admission并drain已有 window，再按首个 failure结束；显式 cancel也 MUST等待/清理该 command 的已入场 work，不得留下独立 claim。该 window MUST NOT更改 NetLane normal/reserved slot、source bucket之外的scheduler、SpeculativeEncodedReadBudget、StorageWriteScheduler或partial-retention owner。
- DownloadJob、Reader、UploadSession 和 holder 不得建立第二套网络资格门控。
- 目标页 receiving transport 不得因 current holder depth、播放 underflow 或页面控件状态被暂停。
- 不得缩小**逻辑/retention 7/3或DownloadDemand 7/3**、关闭预下载或降低播放速度掩盖 identity、重复请求或 producer wake 缺陷；
  动画WebP只能在同一physical task内用frame credit与typed flow-control capability控制远端body流量，
  不能恢复2/4 eligibility、whole-body估算budget或cancel/reopen式流控。

## 5. 下载、partial 与 artifact
- HomeLibrarySession MUST 拥有下载投影读取的 admission、代际和关闭生命周期。扫描期间收到的章节事件（包括 revision 替换、停止/删除后的进度回落）优先于旧扫描基线；
  服务替换前 MUST 排空已接纳读取，关闭后不得新增扫描。下载管理两种标签 MUST 自动重绑新服务并在首帧后请求一次 Home-owned reconciliation；
  通知合并必须有界，不能以手动下载压住独立缓存变更，也不能用额外 UI 网络状态机替代投影。
- 下载管理 Presentation MUST 由 `HomeLibrarySession` 持有的 download-management projection 构造首帧并订阅后续更新。
  Home 在首个可见 frame 后或 durable service adoption 后 MAY 后台重建该投影；
  `PersistentChapterDownloadService` 的 orphan discovery 与 chapter snapshot inspection MUST 共用同一个 artifact-index snapshot，
  同一 service 的并发 refresh MUST 合并。打开、重复进入或退出下载管理 route MUST NOT 自行调用 `library.list()`、
  `discoverOrphanedEntries()`、`inspectMany()` 或 cache usage inspection；
  用户显式刷新 MAY 请求 Home 做一次 authoritative projection refresh。
  由于 Home startup snapshot 不持久化 physical cache projection，
  用户首次进入自动缓存/Canonical tab且当前 projection 缺失时，route MAY 在首帧之后通过 Home projection owner lazy 请求一次 authoritative cache-management refresh。
  该首次展示读取 MUST 只投影 physical Canonical/Exact inventory，不得顺带为全部 library entries 重建 `ChapterDownloadSnapshot`；
  真实 durable management invalidation、用户显式完整刷新或需要 chapter lifecycle 收敛时仍走完整 management projection。
  该 authority 返回前 MUST显示 pending state，MUST NOT把 snapshot 中的 exact download summaries 当作 physical cache rows。
  cache usage 只在进入自动缓存页或显式缓存操作时按需检查；
  首次 physical projection 缺失时不得在 cache-management refresh 前后各启动一次重复 usage inspection。
  compact Home entry 参与 Download Manager authoritative refresh 时，
  placeholder pages MUST NOT 被构造成 exact `DownloadId` 或用于猜 canonical index；
  service MUST 以 source/comic/chapter/revision 分组的 durable READY/partial inventory 投影 Exact cache，
  已有 canonical physical binding 仍优先归入 Canonical row。
  exact cache 的 durable identity MUST继续绑定原 source revision；但若同一 `(sourceId, comicId, chapterId)` 的当前 library chapter 已存在，
  projection MUST仅复用当前 chapter 的人类可读 comic/chapter metadata 作为 display alias，并标记旧 revision 为 historical。
  Presentation MUST NOT把 opaque plugin comic/chapter identity、raw source id、`Exact`/`Canonical` 内部术语显示成普通用户字段；
  手动孤立下载、冷Home摘要与删除确认 MUST遵守同一显示合同：复用可证明的当前metadata，缺失时显示通用标题；MUST NOT解析plugin payload或改写exact identity、READY/pin及命令目标。
  historical exact cache MAY按其原 identity 清理，但 MUST NOT转为当前 revision 的手动下载任务。
  cache-management projection MUST仅消费 durable exact index 与 durable physical artifact/partial inventory；hot `DownloadSession`（包括 promoted source-resident local `file/content/asset` body）MUST NOT单独建立自动缓存行。Reader 对可重开本地来源的正常读取 MUST NOT为了 cache-management 可见性物化 app-owned duplicate body。
  Home 路径的 mutating chapter/whole-comic actions MUST 通过注入的 command capability 进入 `HomeDownloadCommands`，
  并在动作执行时读取已采用的 durable service generation；
  Presentation MAY 持有当前 service 订阅/读取 projection，但 MUST NOT 直接以该 service 实例作为 Home mutation authority。
  Standalone/test harness MAY 保留 resolve-latest-service 后的 fallback mutation，
  但任何跨 modal/await 的 fallback mutation MUST 在真正写入前再次 resolve latest service；
  whole-comic policy dialog 若打开期间发生 service generation change，保存 MUST 只写 current queue。
  Home command capability 路径 MUST 直接委托 `HomeDownloadCommands`，
  不得为了该 fallback 合同额外 resolve concrete route service。
- Automatic hot-transfer checkpoint 与用户显式下载 placement MUST 分层。
  `PartialDownloadHandoff` 持久化 unfinished exact-fallback session 时，
  若 backend 支持 transfer-staging capability，MUST优先使用 App-private Direct staging；
  配置全局/来源 SAF 下载目录不得自动把该 mutable checkpoint 变成 SAF placement。
  generic `PartialDownloadStore.storePartialDownload()` MAY继续支持历史/显式 SAF exact partial，
  并必须保持其 owner/restore/cleanup 合同。显式 chapter download 的 SAF 结果只在 promoted durable artifact 已形成后，
  由既有 structured placement/mirror owner 单独提交并最终 pin；automatic checkpoint 不得持有该 final-placement authority。
  若旧 SAF/external exact partial 被 automatic checkpoint 收敛到 Direct staging，
  authority switch MUST先保证新 prefix 不短于旧 authority，并通过 cleanup-debt 机制安全退休旧 locator；失败时不得因迁移而丢失更长旧 prefix。
  persistent canonical SAF physical partial 在 composition local-prepare 命中时 MUST由 persistent store 的同一 per-physical serializer 先迁移为 App-private Direct transfer staging，再把该 mutable spool adoption 给 hot DownloadSession；MUST NOT 经 DownloadSession writer 从0复制 SAF body并把本地 replay 发布成 network receiving。迁移旧 SAF prefix 时 MUST在实际copy中累计obsolete-prefix length+CRC cleanup proof，MUST NOT为hot takeover另做完整pre-copy扫描；新Direct authority提交后旧locator清理由durable cleanup-debt owner异步完成并在删除前重新验证非authority/length/CRC，Reader cancellation MUST NOT等待该清理。scheduler TaskControl MUST贯穿authority switch前的迁移：switch前取消保留旧SAF partial，switch后retry MUST直接使用新Direct authority。详见ADR 0340。
  借用 staging 的reset MUST经原持久化 owner清理canonical READY及无其它binding引用的副本，不得只删索引而留下旧正文供fresh handoff恢复。
  已不存在的canonical READY/partial记录 MUST允许幂等失效；存在的借用正文 MUST继续拒绝外部删除，pinned/shared exact正文 MUST保持原有引用保护。
  \n- 若 route 首帧仍绑定 bootstrap services 或 durable handoff 尚在进行，
  同一个下载管理 route MUST 在首帧后 force/await Home core-service handoff，
  adopt 匹配的 chapter-download/whole-comic/cache bindings，重绑 service stream，并立即读取及持续订阅 Home 最新投影。
  route 存活期间 `HomeServiceHandoff` 再发布 service identity change 时，MUST 使已 resolve generation 失效；
  下一次 service-side read、cache inspect/trim/clear 或 standalone fallback mutation 前 MUST resolve/adopt current bindings。
  若 generation 在 resolver in-flight 期间改变，旧 resolver 完成后 MUST 再 resolve 新 generation；
  不得用 one-shot resolved flag 吞掉变化。cache clear MUST 在用户确认 dialog 返回后再 resolve 并固定 current coordinator。
  实现 MUST NOT 在该 route 生命周期内继续固定使用 bootstrap/superseded service，
  也 MUST NOT 为修复首进空白而恢复 route-owned 全量索引读取或要求用户退出后第二次进入。
- 整本下载进度 MUST 只有 `DownloadSession -> ChapterDownloadSnapshot -> WholeComicQueueJobSnapshot` 一条投影链。
  whole-comic queue MUST 订阅章节变化、拥有章节集合并按页发布 `completedPageUnits/totalPages/completedPages/hasPendingWork/fraction`；
  Home 封面与下载管理 MUST 消费同一个 whole-job 快照，MUST NOT 分别按章节数或自行聚合章节快照形成第二进度事实。
- GET/HEAD MUST 零 body且不得携带仅适用于实体 body 的 headers。
- 同一 DownloadId MUST 只有一个 active writer；partial MUST 是连续前缀并可恢复。
  对同一稳定 DownloadId，已经提交并成为 playback authority 的 `committedLength` MUST 单调不减；
  transport restart、missing validators、Range rejection、
  retry 或 source-open fallback MUST NOT 删除、截短、换 epoch 或重建仍与 artifact 一致的内存 Ingress。
  同一actual request URI的strong validator可直接Range resume；
  validator缺失或仅存在其他provider URI的validator且旧 total length已知时，
  DownloadJob SHOULD先用最多64 KiB尾部 overlap Range验证continuity，
  并且只有精确206、精确range start、total length一致和overlap逐字节一致时才可从旧 boundary继续append。
  若服务器忽略Range并以200返回完整body，MUST复用该同一response进入full-prefix catch-up，不得因probe失败再次打开第二条full response；
  probe不可用时才MAY直接从byte 0 catch-up。full-body continuation MUST使用bounded cost admission：partial<1MiB不得因成本门槛阻止；
  1MiB<=partial<8MiB时priority>=820才可继续；partial>=8MiB时priority>=900才可继续。
  defer MUST立即释放当前response并保持artifact/Ingress/epoch不变。Range probe本身仍MAY执行。
  coordinator MUST以DownloadId+当前committedLength记忆defer，低priority demand detach/re-add在partial未变化时不得重新联网；
  committedLength变化或priority达到对应门槛时 MUST清除defer并重新probe。
  该记忆不得持久化为endpoint Range能力，也 MUST NOT读取endpoint hash、`duplicatePrefixBytes`或decode/playback诊断作为admission输入。
  已经开始的不可恢复full-body attempt MAY 将取消后必须重付的attempt wall time与response consumed bytes作为NetLane victim-retention成本事实；
  NetLane MUST以连续、单调、有上限的函数形成restart-cost retention：
  当前用5s时间尺度与4MiB流量尺度形成`costScore`，同时计算bounded +100与base→current-safe headroom两种投影，
  并固定取`1/3 bounded + 2/3 headroom`。
  logical detach把base降为0后 MAY保留成本保护，但 MUST NOT仅凭历史投入占满整个base→current-safe剩余rank空间。
  该投影 MUST NOT提高task的admission/pending priority，且current=1000 MUST始终保持配置的preemption margin。
  普通可Range-resume的committed工作、endpoint hash、HTTP version或网速估计 MUST NOT直接产生该bonus。
  所有重复校验字节 MUST NOT写入artifact/Ingress；mismatch、取消或提前EOF MUST保留旧playable partial；
  其中typed `ErrorCode.cancelled`无论从DownloadJob还是其他generic fail closure进入，
  都 MUST机械转为writer pause而不是content failure，真实network/content/validator/artifact错误才 MAY进入failed。
  `resumeAccepted/resumeRestarted` MAY记录只读`resumeProbe*`与`duplicatePrefixBytes`诊断，
  但NetLane/Reader/retry/cache MUST NOT读取这些字段形成policy。
  只有明确owner/identity mismatch、artifact corruption或显式evict/清缓存 MAY使committed playback bytes减少。
- seal/promotion MUST 原子形成可持久裁决的 metadata authority；cache clear 不得删除 active artifact。
  Artifact partial→final promotion的data-file rename与内存state切换之间不得向Reader泄漏人工0字节窗口：
  readBytes/readChunks/readPrefix MUST由Artifact owner在preferred path open失败时只fallback同一Artifact的alternate partial/final path，
  并以已打开file handle完成读取；Reader/sessions MUST NOT自行选择promotion path。
  sealed READY 的 durable authority MUST 只来自 SQLite `artifact_object` 的 immutable bytes/checksum proof 与 `artifact_replica` 的 physical locator；
  exact/physical READY 的foreground presentation open在locator/exact-length/provider proof成立后 MUST先返回正文/descriptor capability，
  LRU/recency touch只能由既有`StorageWriteScheduler`异步合并写入，
  MUST NOT把SQLite metadata write pressure串回`presentation-file-lease`；
  `cache_entry.path`、final `.meta`、session owner字段和文件名均不得成为第二套 READY owner。
  dirty `StartupRecovery`/`CacheScanner` MUST保护任何仍由 DB replica/partial/migration/live owner 命名的locator，
  并 MUST NOT 因 READY sidecar 缺失、ownerless、格式错误或字段不一致而创建、删除、重建或修复 sealed authority；
  READY 也 MUST NOT 为启动恢复重新 materialize `DownloadSession`。
  真实正文缺失、unsafe locator、Direct exact-length mismatch 或 SAF按其二次确认规则成立的结构失败 MUST 继续由正常 artifact/replica read path typed 检测并只退休相应坏 replica。
  mutable partial/spool MUST保持独立authority；
  sidecar MAY携带validators、resume或collision辅助事实，但 MUST NOT把未提交正文升级成READY。
  `storePromotedArtifact`遇到matching READY时 SHOULD直接通过artifact/replica preflight复用，而不是先session restore或修sidecar；
  用户显式persist/manual download需要exact durable时仍 MUST建立exact binding。
  sealed partial→READY 的 filesystem rename 与 SQLite authority commit MUST 通过 schema-17 `artifact_promotion` progress journal 闭合：
  journal 仅可由已索引sealed length/checksum proof建立，必须同时记录source/destination候选且本身不得成为READY。
  重启时只能按journal proof验证destination或source；
  source命中且destination缺失时 MAY rename+复验后提交，foreign destination MUST fail-closed回到原partial，
  任何路径都不得解析final sidecar作为proof。最终 `artifact_object`/`artifact_replica`、exact READY、
  canonical physical binding、partial退休与journal删除 MUST在同一SQLite事务完成。
- `DownloadJob` MUST 是 page-body transport chunk aggregation的唯一owner：
  任意底层小块先形成首批约16KiB，之后按64KiB `sourceProgressQuantumBytes`提交session。
  `DownloadJob` MUST对每次network body read以及每次transport open（`_open`/`_openRange`）施加read-stall watchdog（`defaultReadStallTimeout`默认6s，
  经`DownloadTransferOwner`/`CompositionDownloadTransferRuntime`/chapter command可注入同一窗口）：
  open或一次read在窗口内既未返回也未完成 MUST以typed network failure结束attempt（open超时还 MUST对迟到的response执行discard，
  防止底层请求泄漏），使静默阻塞（挂起的插件运行时、无RST的死socket）的已admit任务自行结束本attempt——open阶段不受读watchdog覆盖会让任务在首个字节前永久占用task key、
  阻断一切重试准入；watchdog只覆盖真实open/read，flow-control park等待（`waitBeforeRead`）不受其约束。
  进入 provider attempt loop 后，同一 transport/open/body failure MUST 只消费 consumer `RetryPolicy` 的 attempt budget；
  该 budget exhausted 后 physical owner MUST直接发布 terminal failure，MUST NOT再以 owner recovery 重新创建一组相同 attempts。
  owner recovery MAY仅覆盖进入 attempt loop 前的 provider/setup network failure。
  claim/role/priority-only scheduling churn MUST NOT清 terminal failure或重置该 recovery budget；
  只有真实 committed progress、成功完成、明确 physical generation reset/replace 或 session retirement MAY重置。
  chapter page-promotion stall MUST表示连续**无实际进展**窗口而非整页总耗时：
  即使transport chunk尚未累计到64KiB snapshot quantum，只要当前physical attempt的`networkCursorLength`或authoritative `committedLength`自本窗口起点增长，
  就 MUST重新计时；不得为了该检测提高DownloadSnapshot/trace发布频率。
  composition-owned transfer中，单次`DownloadJob` network/setup失败 MUST只清理本attempt并保留idle/resumable partial，
  MUST NOT在`DownloadTransferOwner`仍允许retry时发布consumer-visible terminal `failed`；
  最终失败 MUST由physical owner在retry exhausted后唯一发布。
  page-promotion watchdog在lower run处于queued transport-open或active network body且lower read-stall watchdog有效时 MUST让权给该lower timeout owner并重新计时，
  只有没有lower active phase且没有真实cursor/committed增长时 MAY做session reclaim；不得让两个同一窗口watchdog通过竞速reset决定结果。
  `DownloadTransferOwner` MUST在结构化trace中以reason-set变更去重的方式记录download task被跳过的原因（active-run/has-writer/terminal-failure/deferred-at-length/retry-rounds-exhausted/local-preparing等），
  chapter command MUST在stall回收路径记录page-promotion-stall/reclaim/gave-up事件，二者共同构成真机停摆诊断轨迹。
  production rhttp direct transport对rangeStart=0的完整/首段response MUST执行媒体前缀验证并保持raw streaming cadence；
  合法206且`Content-Range.start > 0`的中段 MUST跳过完整文件magic-prefix要求，MUST NOT仅因中段不含图片文件头而转runtime fallback。
  rhttp transport MUST NOT再次增加64/256KiB framing；底层packet边界也不得直接放大为数万次artifact/native append。
  scheduler cancellation MUST覆盖response完整生命周期；
  request已返回并开始stream后，consumer/task取消仍 MUST abort底层source/HTTP response。
  response cleanup MUST共用原终止Future，重复discard与control取消不得提前完成；
  DownloadJob取消/正文watchdog收尾 MUST先启动原response abort，再join正文订阅与discard，不能让正在等底层输入的Dart流阻止abort发出。
  发出native取消后 MUST等待原stream的typed取消或EOF，再关闭Dart订阅；主动取消的终止结果 MUST让已取消正文正常退出，不能逃逸为未处理错误或阻塞原任务退休。
  partial artifact append MUST NOT在UI isolate逐chunk执行checksum CPU循环；
  checksum MAY延迟到seal/restore边界计算，但seal/promotion前 MUST成为权威且通过expected checksum验证。
  rhttp response 的HTTP version与匿名 remote-IP hash MAY作为每response一次的低开销诊断随`sourceRead`输出；
  高频receive-progress/raw-body diagnostics MAY在bridge边界记录event/gap/byte统计，
  但普通product/release MUST默认关闭`onReceiveProgress`注册，只有non-product或显式`ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS`诊断构建 MAY启用。
  该progress是限频的Dart stream交付观测，MUST NOT当作独立socket接收时间；正文gap/streamMicros包含consumer pacing与permit停驻，归因网络前 MUST对齐这些区间。
  所有这些字段 MUST observation-only，MUST NOT驱动NetLane、Reader、retry、cache或chunk framing；
  不得仅因current吞吐较低就新增第二个bandwidth scheduler。
  generic 6s transport-open watchdog MAY仅在当前URI的transport显式实现`SelfBoundedOpenTransport`且返回true时省略；
  该capability MUST证明完整lower open由有限deadline覆盖，MUST NOT因为source类型、历史耗时或最终diagnostics推测。
  external source的proof MUST同时要求source resource plan/load有正的runtime-owned operation timeout与direct media transport有独立有限open deadline；
  正文读取仍 MUST逐次受6s inactivity watchdog约束。
  self-bounded open或报告该phase handoff的open在scheduler取消后 MUST等待原pending Future和迟到response的discard退出，再完成原lane task。
  cache/read-through wrapper转发已证明self-bounded的fallback时 MUST保持同一退出边界，不得以取消Future赢得竞速而提前归还容量。
  该 proof MUST 与 per-page controlled response loader 原子跨 App/LocalMedia composition 传入 `LoaderTransportSource.selfBoundedOpen`；
  不得只保留 loader closure 而丢失 capability。transparent wrapper若自身在fallback之前还执行未独立有界的cache/storage lookup，
  MUST NOT把整个wrapper仅因fallback self-bounded就声明为该capability；
  它 MUST让generic watchdog继续覆盖本地阶段，并且只有在本地阶段完成、即将调用已证明self-bounded的fallback时 MAY通过同一scheduler-owned `OpenPhaseReportingTaskControl`报告一次phase handoff，
  使DownloadJob只撤销当前open timer而继续等待同一pending future/cancellation。
  该report MUST NOT携带timeout值、设置priority/retry/admission或形成第二timer；body inactivity仍由原6s watchdog唯一负责。
  generic open watchdog超时时，DownloadJob MUST先确定性发布`ErrorCode.network` attempt failure，
  再abort仅属于本次controlled open的attempt-local TaskControl；MUST NOT调用真实scheduler CancelToken的cancel。
  该私有control MUST透明代理实时priority、priorityChanges与scheduler cancellation/OpenPhase reporting，
  使下层I/O能物理退出而owner仍按原retry policy处理network failure。
  已经超时的cache/storage lookup即使之后完成，也 MUST在进入任何origin fallback前观察attempt abort并停止，
  禁止NetLane task key已释放后产生zombie source request。
- local 和 remote WebP decode-prefix hint SHOULD 分别使用 1 MiB 和 256 KiB quantum；该 hint 不等同于 transport chunk。
  对 logical URI 仍为 remote、但正文已经由 durable Direct/SAF immutable authority 本地重放的 generation，
  decode-prefix quantum MUST 依据当前 physical replay access cost，而不是原始 URI scheme；
  初始 Reader ingress MAY 只 hydrate 256 KiB 探测前缀，后续增长 MUST 由 DecodeSession 的 `requiredSourceLength`/native need-more-data 驱动并按 physical-local quantum 对齐，
  且不得因此扩大 Download/Decode/Upload page eligibility。
- exact durable READY 的完整正文 authority 与 Reader-local ingress hydrated boundary MUST 独立：
  physical DownloadSession MAY 在 ingress 仍为空时已经是 promoted/complete，
  Reader 只有在既有 DecodeDemand/UploadDemand/retained output 拥有 media source 时才建立 projection，
  并按需回放 contiguous prefix。
  durable completeness MUST NOT 再通过“先把整份 READY 当 partial 从 byte 0 全量复制进 Reader ingress”证明。
  若 backend 能提供 generation-bound exact-range reader，
  exact-length preflight 与后续 range replay SHOULD 复用同一 descriptor/handle；
  generation reset/rebind/dispose MUST 关闭并失效该 capability。
  SAF 的 startup foreground pressure MAY 阻止 background SAF quantum 进入单线程 provider executor，
  但 MUST NOT成为新的 page-role/priority eligibility gate，Direct/POSIX 的正常并行也不得因此被全局收紧。
- 读取失败 MUST 保留可归因错误，不得表现为永久 loading。
- Home/书架漫画卡片的下载完成勾 MUST 由本次显式下载命令完成事件驱动，而不是由任意 durable chapter cache命中推导。单章节命令完成 MUST 使用与整本完成可区分的空心标记；
  整本下载仅在 whole-comic queue进入 complete后 MAY 显示绿色实心标记。完成标记 MUST 为临时 Presentation状态，并在进入该漫画详情时清除；
  durable离线事实继续属于 downloads/artifact。
- 设置 MUST 提供单行"默认下载目录"项：该行同时展示当前生效的章节下载目录并直接进入目录选择，不得像 Venera 一样把路径展示与设置动作拆成两行。用户选择的目录按旧/新文件规则解析生效位置：
  缺失或空的所选目录直接作为下载根；
  非空目录 MUST NOT 被合并或覆盖，存储改置于其下第一个可用的 `offline_chapters`、`offline_chapters(1)`… 条目（已存在但为空的条目 MAY 复用）。
  切换目录时用户 MAY 选择是否迁移。已有 App-private metadata 时，explicit Direct-root migration MUST 逐 sealed replica 执行：只迁移 verified READY 且由显式 manual/offline retention 保护的物理副本，MUST 保持 `replica_id`，并在删除 source 前提交 destination locator/root authority；automatic-cache-only bytes 与 mutable partial/spool MUST NOT 因根切换被强制迁移。结构化 manifest MUST 在 replica 全部提交后先 durable copy/verify，再推进 `DownloadPlacement` generation/root。MUST NOT 仅递归搬完整个根后统一重写 SQLite 前缀。
  不迁移时旧 replica/partial/cache MUST 保留在原物理位置，新目录只成为后续 materialization 目标；Direct 旧 locator 仍可按 durable index 读取。旧 SAF tree 在切走当前 grant 后的可访问性属于独立 SAF authority 问题，MUST NOT 因“文件仍存在”而宣称仍可读。新、旧 Direct 目录相同或存在嵌套关系时 MUST 拒绝迁移。意图（目标目录、迁移来源与 migration protocol marker）MUST 先于迁移持久化；中断后 MUST 保留 source layout + pending intent，并由下次启动在同一 App-private artifact authority 上幂等续作，已提交的 destination replica MUST NOT 回滚或重复复制。若 source 或 destination 任一为 SAF，当前 UI MUST 禁用 automatic existing-download migration，不得把 Direct/POSIX 迁移协议冒充 SAF provider 原子性。
  有整本任务进行中或 Reader transfer consumer 未退出时 MUST 拒绝立即切换并保持现状。
- 来源管理 MUST 为每个 source 提供齿轮“源设置”入口。应用级 source policy MUST 集中在该页，
  当前包括条漫置信、历史缓存冲突数据信任与来源独立下载目录；这些设置不得重新挂回插件生命周期管理。
  来源独立下载目录默认跟随全局目录，只决定该 source 新下载 artifact 的写入位置。
  既有文件 MUST 保留在原位置并通过索引 locator 继续可读，per-source 切换不要求迁移。
  原可配置来源设置/登录入口 MUST 作为“来源属性与登录”使用属性列表/属性页语义图标，不得与应用级源设置共用齿轮语义。
- 历史缓存冲突信任 MUST 以 source tri-state（inherit/strict/trust）覆盖 application global default。
  旧 plugin-scoped override MAY 只作兼容读取；进入该插件任一源设置时，MUST 将旧值展开到当前全部已知 source IDs，
  保留已有显式 source override。只有 installed-plugin authority 能证明该插件 source 集完整时 MAY 退役 plugin override；
  若 runtime discovery 仍可能存在未发现 source，则 MUST 保留 plugin fallback，直到完整 source 集可证明，避免未发现 source 丢失历史信任。
- 插件管理 MUST 提供更新提醒：进入管理页时按每个已安装插件持久化的精确仓库索引检查更新（版本号优先、无版本号时版本串不同即视为可更新），发现更新时以对话框提醒一次并在已安装行保持可见徽标；
  更新索引 MUST 与 executable-plugin gate 的仓库 trust origin 分开持久化，MUST NOT 把只有 scheme/host 的 trust origin 当作 index 请求。旧记录缺少索引时，仅当 pinned payload URL 能无歧义证明属于宿主历史默认仓库时 MAY 迁移到对应当前默认索引；否则 MUST NOT 猜测。单个仓库不可达 MUST NOT 掩盖其它仓库的更新结果。设备导入且无真实仓库来源的 Mihon 扩展 MAY 跳过检查。
- 已安装 Venera 插件 MUST 支持直接编辑其 JavaScript payload：
  保存属于用户显式信任，编辑内容 MUST 重新经过受限元数据检查（source key 与能力可能变化）并以新摘要重新固定后替换运行会话；
  任何检查或激活失败 MUST 保持旧 payload 权威且不得使来源静默下线。
- 来源管理页 MUST 提供单一未分类的可排序列表：原生/Mihon/Venera 混排，由行首图标区分来源类型；
  长按拖动排序 MUST 持久化到 `ComicSourcePreference.sortOrder` 并作为漫画源页底部插件/来源控件的显示顺序。同一 Mihon 扩展的多语言变体 MUST 折叠为单行：
  行代表 = 最近启用的变体（按 `ComicSourcePreference.lastEnabledAt`），点击该行插件图标展开其余变体；
  启用某变体时同族其它已启用变体 MUST 自动停用（每个扩展族至多一个启用源），底部控件对每个扩展族只显示一个 chip 且指向当前启用的变体。

## 6. Animated WebP

- 两个 Dart decode isolate MUST 在 App 运行期常驻；libwebp 帧内 MUST 单线程。
- 首次 decode SHOULD 优先单帧；current 后续 MAY 每次批量返回最多两帧。
- holder MUST 是 decoded successor 的权威所有者；可见 output 不得计入 successor depth。
- current bootstrap MUST 优先建立静态1帧或动态最多3帧的浅水位；动态 bootstrap 未满足时 speculative neighbor refill MUST 为0。
  current 等 source 时，真实 transition depth=0 MAY 独立取得1帧；单帧 current 暂不可执行时 MAY 释放既有单帧静态邻页，MUST NOT 绕行多帧水位。
  bootstrap完成后恢复 staged current/neighbor refill；单帧等待例外 MUST NOT改变 encoded/network admission、窗口或并发。
- 不得恢复独立 startup-buffer 或以 playback timer/underflow 控制网络 eligibility；
  current bootstrap 只属于 decode refill policy，不创建第二套 Reader gate。
- metadata 未完成且 source 增长时 demux MUST 可刷新；未封缄 need-more-data MUST 等待 source revision，而不是定时销毁 cursor。
- source revision MUST 保持 pending，直到对应 DecodeSession 实际执行 fill，或其当前 snapshot 明确证明无需 fill；
  staged refill policy 因 current bootstrap 暂时返回空决策 MUST NOT 被解释为 source 已消费。
  角色晋升为 current 后 MUST 能从 projection 当前 revision/state 重新发现已就绪 source。
  DecodeSession的generation authority MUST唯一来自当前Reader-local ingress projection；
  MUST NOT同时读取physical DownloadSession epoch进行第二份preflight。
  若projection epoch在异步decode期间变化，旧work MUST按生命周期cancel而非terminal decode failure；
  异步结果与错误回调 MUST先校验原cancel/session/demand/ingress epoch及EncodedSource实例identity，再读取source或分类失败；已退休work MUST NOT发布failure或prefix retry，且 MUST等待cursor真正返回再释放原capacity。
  若projection在同epoch内rebuild并替换`EncodedSource`实例，DecodeSession MUST丢弃晚到旧frame及绑定旧实例的cursor/holder，并从当前source重新创建cursor。
  新实例frame0的prefix检查 MUST在旧cursor续帧状态退休后进行；MUST NOT被旧后续帧的字节下限阻塞。同一实例增长 MUST保留有效的per-frame prefix hint。
  实例有效性 MUST按底层Ingress identity判断；synchronized replay只暂时隐藏可见source时，MUST NOT取消已绑定同一实例的fill。
  LiveCoordinator MUST NOT把返回`failed/failure`的DecodeSnapshot记为已消费source revision。
  Reader ingress registry的`get(session)` MUST区分physical object generation与Reader encoded generation：
  same DownloadId的新physical session仍属于新的physical object generation；
  unfinished/failed或仍有pending synchronized attachment的same DownloadId新physical session MUST创建fresh Reader-local projection/source；
  若existing projection已经sealed、sourceReady、无failure且无pending attachment，
  则same exact DownloadId的transient DownloadSession recreation MAY保留同一immutable Reader encoded generation，
  并 MUST NOT因此invalidate decode/upload。旧same-id physical teardown MUST做concrete session identity校验。
  synchronized late join MUST在加入physical live fan-out前同时证明physical boundary稳定且projection snapshot的epoch/length/sealed/failure精确闭合，
  MUST NOT仅因physical revision未变就宣称incomplete projection已attached。
  已发布的same-epoch source若精确匹配physical length/sealed且无failure，late join MUST复用该对象，MUST NOT因source已sealed而再次从零rebuild。
  UploadSession在physical-generation invalidation触发的dispose MUST立即退休当前uploader slot并清除deferred-release请求；
  旧generation pending prepare随后结束 MUST NOT再次按logical DecodeId release replacement generation。
  普通demand detach的pending-upload release语义保持不变。
  UploadRegistry MUST把logical DecodeId与concrete DecodeSession generation区分：
  `get/prepare`命中既有UploadSession时 MUST验证`identical(existing.decode, decodes.get(id))`；
  不一致时 MUST先dispose旧UploadSession再创建replacement，MUST NOT把旧holder为空解释为当前DecodeRegistry仍无frame，
  也MUST NOT让UploadSession在生命周期中动态切换DecodeSession。
- native target canvas MUST 生成预乘 RGBA；Flutter fallback output与Android production output均不得再次预乘。
- finite animation 到 EOF MUST 保留最后一帧；静态零时长帧不得启动 playback timer。

## 7. Upload 与 renderer output
- Texture bridge 的 `scheduleFrame()` 合并边界按 `SurfaceProducer` 独立计算，并保持到下一次 Android vsync；
  合并只减少重复平台消息，不改变最新 resident frame 或 MethodChannel 完成语义。

- replacement 前旧 frame MUST 保持有效；release MUST 等待最后一个 frame owner。
- 生产Reader Android SurfaceProducer output MUST使用一个串行blit lane，
  `scheduleFrame()` MUST在platform thread执行；MethodChannel result MAY在对应完成边界由blit/回包线程发送，不得为回包延长UI turn；
  同一 output 在主线程忙于 Flutter frame 时 MAY 合并待调度回调，但 MUST 对每个调用完成回调，且以最新 resident frame 执行一次真实 `scheduleFrame()`。
- SurfaceProducer的platform queue、schedule queue/call、blit和channel dispatch MUST分别计时；
  正常逐帧 `TexturePresentTelemetry` MAY 不另写一条重复 `frameUploaded` Trace，
  完整 timing MUST 继续保留在 `OutputFrame` 并由 startup/stall 的 `framePipelineTiming` 归因，
  达到 20ms、deadline miss、surface reconfigure 或 fallback 的 platform 样本 MUST 保留。
- Flutter `ui.Image`或已承载output的texture/SurfaceProducer MUST随output释放，不得跨Reader会话复用。
- 只有从未呈现过的 prewarm lease MAY 短期复用；App 非 resumed 时 SHOULD 清理 idle prewarm。

## 8. Reader 资源会话生命周期

- Reader Host MUST 通过 factory acquire/release 资源会话，不能在 Widget dispose 中直接销毁所有章节资源。
- 实现 MAY以两分钟TTL保留最多两个idle exact session key；第三个key MUST淘汰最旧项，仅保留download/encoded body authority；
  physical Download状态 MAY由composition transfer runtime独立于该Reader retention继续持有，
  但不得因此保留已退出Reader的native ingress/transport provider。
  Reader-local decode/upload、cursor/canvas、frame与ingress/source MUST在退出时由原Coordinator退休；
  仍真实执行的任务 MUST保留原具体source/cursor到原Lane退出回执后回收，不得提前evict或等待retention TTL。
- retention key MUST 使用稳定章节/source/loader revision，不得依赖临时 loader 对象 identity。
- retain 时 MUST 释放 Reader binding、page projection、playback wake、present claim和 used texture。
- TTL、key 变化、容量淘汰或 composition shutdown 时 MUST 完整逆序 dispose。
- retention 不得成为 Reader 私有正文缓存或 used texture cache。

## 9. Identity 与缓存
- 持久化 imported-library 的 bulk list 查询及 JSON/model 解码 MUST 由 storage-owned 短生命周期只读 worker 执行；
  UI-owned SQLite connection/handle 不得跨 isolate，关闭 MUST 等待已接纳的 bulk read。
  bulk list的worker MUST在传回记录前完成record-local不可变manifest投影，首次页面URI解析 MUST NOT遗留到Home的foreground authority构建；authority发布 MUST仍由原runtime owner执行。
  Home章节upsert MUST保留持久化回读及最新progress；仅在完整持久化payload一致时 MAY复用传入不可变记录的已准备manifest。实际metadata、页序或locator变化 MUST采用回读结果；不得新增scope级缓存或延迟authority提交。
  详情的来源章节准备在source fallback前 MUST先通过session hydrate已有exact source/comic/chapter的持久完整记录，再检查revision、已知pageCount与locator有效性；有效记录 MUST保留importedAt及最新进度，MUST NOT仅因紧凑Home占位投影重载来源。缺失、版本/页数变化或旧locator MUST继续来源加载。
  内存 store 仍按有限工作量让出 event turn，且不得跨让步持有 SQLite 事务；精确章节读取和显式原子备份保持原有窄路径与事务语义；
  cache schema 20 MUST 为 `artifact_replica(access_locator)` 提供非唯一查询索引；
  v19→20 只安装该索引，不重放历史 identity backfill、不改变 authority、不跳过 crash recovery。
  `CacheScanner` 的 trace MUST 分开记录 `cacheScan.scanMicros` 和 `phaseMicros`；
  DB/live owner 已保护的 sidecar MAY 作为扫描提示免除冗余正文类型探测，但不得代替正文存在性、缺失 partial 校验或持久归属证明。
- 设置 MUST 提供缓存上限（MB，默认 512，范围 64–8192）。该上限是用户对页面 artifact 容量策略的单一输入：持久 artifact 层按上限整理、回落到其 75% 目标；
  response 目标保持固定小默认值。更新策略 MUST 只在下次维护/trim 生效，设置页 SHOULD 在应用后立即触发一次 trim 并刷新用量统计。
  上限 MUST NOT 改变 retained artwork 的显式失效规则或 response cache 身份。
- 同一 request plan、DownloadSession、artifact 和 decode task MUST 按稳定 identity 合并；旧 epoch/revision 结果不得提交。
  ContentId、DownloadId 与 DecodeId 的新字符串 key MUST 使用长度 framing；
  旧 delimiter key 只能用于兼容读取/恢复，新的 cache/index/metadata 写入 MUST 使用 framed key，不能因 source/comic/URI 字段包含分隔符而发生碰撞。
- 封面、详情、搜索和章节元数据 MUST 由统一 response cache 拥有，key 包含 namespace、稳定 identity 和必要 revision。
- Promoted Reader artifact MUST由唯一`ArtifactCacheManager`/persistent cache backend拥有；
  未promoted partial MUST与immutable cache分离。
  physical `DownloadSession`的`committedLength/residentCacheBacked`只声明transfer/residency状态，
  不得隐含session artifact一定保存同一正文；
  late Reader对resident immutable body的encoded-source replay MUST由Reader-local replay authority向唯一`ArtifactCacheManager`查询，
  或对可重开`file/content/asset` source读取严格有界prefix，且read quantum MUST继续经过composition artifact-read scheduler。
  hot partial与source/network task的owner MUST是应用级`CompositionDownloadTransferRuntime`，
  Reader、prefetch、chapter command与whole-comic不得创建第二套physical registry/job；
  它们只能以scoped `TransferDemand`/aggregation表达需求。priority MUST只决定竞争顺序，不能替代completion语义；
  显式durable download的required-completion claim MUST允许在获得执行槽后完成costly full-body catch-up。
  logical consumer/claim退出 MUST只改变调度需求，不得从sessions层触发durable partial I/O；
  hot physical registry MUST由composition owner而非Reader/Pipeline执行有界retention。
  idle promoted immutable session MUST由downloads composition owner保留默认最多8个的LRU hot physical generation；
  普通claim/window detach不得立即全量退休，只有超过promoted hot budget的oldest victim才 MUST先等待现有ordinary artifact handoff收敛再机械退休。
  该预算不得改变Reader encoded/decode窗口、NetLane response容量或ArtifactCacheManager byte ownership；
  unfinished idle prefix在独立hot partial预算受压或runtime最终dispose时仍由downloads层`PartialDownloadHandoff`持久化后退休；
  App进入paused/detached时composition owner SHOULD对当前committed hot partial做durable safety checkpoint，
  但 checkpoint MUST NOT退休hot owner或改变session generation。cold-store失败 MUST保留hot owner。
  persistent store把durable partial借给composition `DownloadSession`后，
  正文 MAY由该session继续append，但持久`cache_entry`/`physical_partial`/`physical_media_artifact` mutation ownership MUST继续属于`PersistentDownloadArtifactStore`；canonical SAF physical partial若尚不可直接borrow，store MUST先在自己的serializer内完成同authority SAF→Direct staging迁移，不得让session先进入receiving后逐字节重建同一prefix；
  provider对非零Range返回200/rangeStart0时属于transport capability/rejection，MUST保留partial并沿现有cost-aware full-body-prefix-catchup/defer处理，不得据此清零durable partial；
  adoption初始sync在store serializer内完成，后续sync/reset/evict MUST经注入的mutation owner回到同一per-id serialization domain，
  MUST NOT由session私有cache tail直接写同一持久row。
  sessions层的retire primitive MUST只处理claim/task/session/alias机械生命周期，不得依赖durable store或retention budget。
  promoted artifact完成反馈必须等待唯一durable store handoff可读；
  同一promoted immutable session的自动handoff成功后 MUST对后续snapshot/demand churn幂等，
  但显式required exact barrier MUST重新验证目标durable。
  跨版本equivalence在新exact identity尚无session且direct verified proof命中一个或多个可复用既有physical owner时 MAY在acquire前绑定到其中一个；
  multiple owners MUST以稳定authority排序择优复用而不得创建第三owner，
  已存在session之间仍 MUST保持分离，source-resident非cache body MUST保持exact。
  physical session MUST only be created by transfer acquire/reconcile；
  Pipeline/Reader presentation/read-only projection MUST use non-creating lookup and MUST wait until verified-equivalence resolution completes before observing the resolved owner，
  MUST NOT precreate an exact session。该runtime alias不得改变exact cache/offline identity。
  Animated WebP holder/cursor与partial-prefix循环资格 MUST只属于DecodeSession/playback，
  不得成为cache persistence、network resume/admission或Download ownership输入。
  循环资格 MUST至少包含2个真实decoded frames，并且 MAY在达到既有`partialLoopMinFrames`门槛（当前默认30帧）或累计decoded frame duration达到1秒时成立；
  duration路径只用于避免低帧率partial已经有足够可播放时长却被固定帧数冻结，MUST NOT形成新的transport/download水位。
  若unsealed partial在needMoreData时已有足够循环证据但仍有buffered frames，
  消费最后一个buffered frame后 MUST允许既有decode refill重新评估partial-prefix loop；
  该late eligibility MUST只由DecodeSession观察事实表达，MUST NOT伪造source revision或放宽其它waitingSource等待。
  对unsealed WebP且尚无成功frame的decode exception MAY转为有界prefix-growth wait；
  sealed source或已有成功frame后的decode exception MUST保持authoritative failure。
- 页面热字节 MUST 有界；默认可为 10 项/256 MiB。App/Reader 不得创建第二套图片 byte LRU。
- artifact reuse MUST 有 checksum、来源 page key、内容 hash 或来源确认关系上的强对应证据；标题、URL token 或相同页码不足以证明等价。
  已确认同源版本 MAY 在不迁移实体的情况下按VibeVenera-compatible compact mapping复用缓存：
  opaque locator由既有source request-plan owner只在mapping准备阶段解析首/中/末anchor，多页重叠至少2个anchor一致即可确认affine offset；
  anchor index只作为bounded proof metadata，accepted offset覆盖整个重叠区。
  mapping无需固定TTL重验，只有chapter/pageCount/sourceRevision等结构事实变化才失效。Reader恢复先查自己的exact DownloadId；
  跨版本fallback只从一次batched exact-key existing-state查询得到的**当前READY或indexed partial**，
  以及composition runtime按同一acquire authority确认可join的hot physical session建立bounded in-memory symmetric equivalence；
  source-resident非artifact-cache body不得作为跨identity hot authority，target exact已存在则不注册。
  未缓存且无hot物理状态的页、以后才promote的页不得预注册future/lazy relation，Reader miss不得为cache reuse额外调用source。
  equivalence是lookup fallback而非storage redirect，不改变exact写入identity、`artifact_id`、replica或pinned状态；
  persistent backend仍exact-only，`ArtifactCacheManager`不得持有directed hard alias/rekey。
  普通Reader可直接消费verified-equivalent durable authority而不复制正文；
  显式required-completion或迁移若要求target exact durable，可沿既有zero-copy binding/materialization建立target exact authority。
  跨版本partial仍只能作为字节前缀复用，MUST清空旧provider validators，后续resume/continuity由target实际request URI裁决。
- cache hit 不得共享 playback timer、cursor 或 decode identity。
- Sealed artifact 的 logical binding、immutable proof 与 physical replica MUST 是独立权威。
  当前 schema 8 中 `artifact_object` 只保存 artifact 的 bytes/checksum proof 与兼容 locator mirror，
  `artifact_replica` 保存一个或多个真实 sealed copy；
  v7 升级 MUST 将既有 ready object 作为 `replica_id == artifact_id` 的首 replica 回填，partial MUST 不进入 replica 表。
  独立 replica 只有在 exact length + CRC32 全验证后 MAY 注册；
  普通 binding/path 更新不得据此推断第二份 bytes，已证明同一 root 的 Direct/SAF locator MUST 复用同一 replica identity。
  读取时结构性 `missing/staleLocator/shortRead/lengthChanged` 只 MAY 淘汰对应 replica，其他 replica 与 logical binding继续有效；
  `accessDenied/ioFailure` MUST NOT 因自身删除 replica。
  caller已经持有逐页verified equivalence且source exact sealed artifact重新通过存在性+exact-length preflight时，
  显式migration MAY用metadata-only commit令target exact logical binding引用同一`artifact_id`；
  该commit MUST NOT读回/复制整个正文，MUST NOT改写`artifact_object`或`artifact_replica`的物理locator/authority，
  MUST NOT把source `pinned`/retention传播给target。
  backend不支持该capability或preflight无法成立时 MAY回退到独立target body materialization。
  target此后若产生不同physical path或正文，MUST脱离shared artifact identity并建立自己的immutable artifact，
  不能借旧`artifact_id`覆盖source正文。
  多个ready logical bindings共享同一`artifact_id`时，容量、trim target与released-byte accounting MUST按physical artifact只计一次；
  任一sibling为pinned/busy/protected时整个artifact MUST不可由普通trim回收；移除非最后一个binding MUST报告0 physical released bytes。
  最后一个 logical binding 被显式删除时，所有已注册 replica bytes MUST 一并清理，不能只依赖 SQLite cascade 删除 metadata。
  Direct/POSIX immutable locator的一次exact-length mismatch仍可直接形成`lengthChanged`；
  SAF/provider locator的单次异常长度观测不足以形成破坏性authority，MUST经独立reopen/re-stat再次确认不一致后才可按structural failure退休replica，
  第二次若恢复正常则保留并继续使用该replica。
- 下载 metadata authority MUST 固定在 App-private `<storage root>/chapter_downloads.sqlite`，
  用户切换下载/导出根 MUST NOT 搬动该 DB；若仅存在升级前生效根的 legacy `cache.sqlite`，startup MUST 用 SQLite 一致快照导入 private DB，
  验证成功前不得删除旧 authority，已有 private DB MUST NOT 被 legacy 状态覆盖。
  persistent artifact store MUST在open期间持有dirty-close marker；
  clean close MUST删除它，只有下一次open发现遗留marker时才 SHOULD运行`StartupRecovery`的authority-aware local orphan cleanup，
  普通clean startup MUST NOT无条件全量扫描。
  该dirty scan MUST保护DB-authoritative sealed replica与mutable partial/migration/live locator，
  MUST NOT从final sidecar创建/修复/删除READY，也 MUST NOT为了READY重建历史`DownloadSession`。
  schema16 `storage_cleanup_debt` MUST只表达non-authoritative exact-locator cleanup而不得取得正文authority：
  generic Direct/SAF atomic-write random temp用`temporary`在create前记录exact locator，确认不存在后才能清债；
  已验证sealed source在metadata authority切换/退休前 MAY以`obsoleteSealedSource`记录旧locator+immutable length/checksum proof；
  mutable partial不得冒充sealed source，但跨locator replacement或cold retirement MAY以`obsoletePartialSource`冻结该次旧prefix generation的实际length+CRC32。
  partial cleanup proof MUST仅在退役边界计算，MUST NOT进入正常append/pause/checkpoint、resume validity或scheduler policy；
  普通physical partial删除失败 MUST保留`PhysicalPartialRecord`直到body+sidecar清除。
  任一obsolete debt跨进程删除前 MUST确认locator已不再被replica/partial/migration authority引用并重新证明当前bytes仍匹配记录proof；
  路径被复用、内容改变或hot session重新接管旧path时 MUST保留新/活跃内容并撤销旧cleanup intent。
  跨locator physical partial copy MUST NOT以较短失败staging覆盖较长旧prefix，
  legacy exact Direct→SAF若旧root不可安全检查 MUST fail closed。
  同一 App-private download metadata DB MUST先取得 absolute index path 的进程内 owner 与 OS exclusive file lock，再允许 SQLite open、dirty recovery、promotion recovery 或 SAF manifest recovery；live second owner MUST fail closed。
  store open MAY异步枚举debt rows并经`StorageWriteScheduler`定向删除，但 MUST NOT因此枚举SAF tree。
  SAF debt只有record tree与当前可访问tree一致时 MAY删除；access/I/O failure MUST保留debt且不得损害已提交target。
  schema9 migration `copying` temp MUST保留用于resume，只有当前可访问的`cleanupPending` MAY由同一异步drainer复用既有cleanup。
  用户下载目录（无论是外部 POSIX 还是 SAF 树）中的漫画文件 MUST 采用结构化目录和 1-based 页文件名。
  Android SAF路径解析 MAY缓存exact provider document id及按父document-id划分的children listing，但这些缓存只作加速：
  App自身create/delete/rename/replace成功后 MUST只失效受影响父目录listing，失败且未发生mutation不得整tree打冷；
  stale exact read MUST先做父目录级恢复，仅当scoped recovery仍失败或provider无法提供必要document id时 MAY整tree fallback。结构化页默认优先使用：
  默认优先使用 `[cleanComicTitle]/[cleanChapterTitle]/[001.ext]`，且漫画根目录 MUST 绑定 exact `(sourceId, comicId)` owner；
  同名不同 owner MUST 使用稳定隔离目录。
  落盘目录与 `incremental/overwrite/createNew` 意图及 `pageOrder`（`ComicPageOrder.auto/chronological/origin`）MUST 以持久化 `DownloadPlacement` 为权威，
  并同时进入单章任务、生产整本队列及其恢复 JSON。
  物理目录缺失（`!dirExists`）或无真实图片（`!hasRealImages`）且无活跃会话认领时，MUST 无条件判定为空闲并释放历史游标，优先分配纯标题目录；
  物理存在的非空目录冲突时弹出用户选择，严禁静默重命名或让历史 SQLite 幽灵记录阻断纯标题目录。
  冲突恢复/`forcePrompt` MUST 将当前 persisted `DownloadPlacement.relativeDirectory` 作为 required conflict target 重新交给 storage conflict inspector，MUST NOT 因目录名不匹配 comic title 而忽略；即使目标目录尚未物化，只要 durable placement owner claim 存在，也 MUST 形成可解释的冲突候选并携带 storage-projected `observedOwnerKey`。UI MUST NOT 从路径、异常文本或标题推断 owner；overwrite 仍 MUST 由 storage owner 对该 observed owner 重新校验。若 Presentation 过滤 exact/self candidate，MUST 另行保留完整 occupied directory 集合用于 `saveAsNew` 唯一命名，禁止重新选择被过滤的 exact occupied 推荐目录。整本任务查找 MUST 使用 `(sourceId, comicId)` 组合身份；相同 comicId 的不同 sourceId MUST 保持不同 job。
  每本漫画根目录 MUST 写入 `.zic.json`，提交前 MUST 重新校验 owner，不同 comicId 不得 last-writer-wins；
  manifest MUST 保存单调 generation、内容 fingerprint、`pageOrder` 和稳定 chapter-id→directory 映射，损坏 fingerprint MUST 拒绝。SAF manifest replace/delete MUST 在任何 SAF mutation 前 flush App-private transaction intent，并保留 deterministic `.zic.json.zic-old` 直到 `DownloadPlacement` commit point；重启 MUST 以 intent + exact token 决定 rollback/forward。无 intent 的较新 target MUST NOT 仅因 generation 更高而推进 placement。generic SAF page/partial 不复用 manifest token，而按 ADR0343 在任何 target mutation 前 flush 独立 App-private body intent，保留 deterministic `target.zic-old`，并以现有 `CacheRec` / `PhysicalPartialRecord` 精确新记录作为唯一 commit point。低层 `commitSafTemporary` 只允许 rename 到空 target；生产路径禁止 `safReplace`、delete-then-rename 和随机隐藏 backup。
  SAF body 的 stale/crash intent recovery MUST独立验证完整 length+CRC，partial 也 MUST NOT以 equal length 代替 staged content proof。相同 partial 重存可能在 mutation 前就匹配现有 index authority；target 缺失时，只有 backup 的完整 length+CRC 与该 authority 一致才 MAY恢复 backup。已存在但 CRC 不匹配的 target、缺失或不匹配的 backup MUST保留 intent/正文证据并 fail closed。正常 live staging/index commit 的清理 SHOULD复用该次 copy 已累计的 proof，MUST NOT因此给普通 checkpoint 增加整段正文扫描；MUST NOT新增 placement/generation 或第二 index authority。
  单章漫画 MAY 将页面直接放在漫画根目录且省略该章 directory mapping；
  首次进入多章布局时只有缺失 directory mapping 的既有章节 MAY 进入 flat→subdirectory 可重入迁移，
  现代 manifest 已有 mapping 的章节 MUST 视为已提交布局、后续新增章节不得再逐章全量扫描 cache index。
  旧 manifest 允许缺失 `chapterDirectories`，因此缺 mapping MUST 保留历史恢复检查而不得被当成已迁移。
  章节命令下载前若已经持有同一 durable index snapshot，manifest writer、
  无persisted placement时的legacy目录恢复，以及旧structured文件的export-ordinal兼容迁移 MAY消费该snapshot以避免同一命令重复全表查询；
  manifest writer MUST在锁内合并当前previous manifest。下载完成后 MUST取得一次 fresh durable index snapshot 作为并发/中断收敛边界；
  final manifest提交与complete状态投影 SHOULD共享该snapshot，不得为了同一完成事件连续重复 whole-index读取。
  caller起始snapshot不得替代该最终reconcile；
  API未收到command-scoped snapshot时 MUST 保留原fresh-index兼容行为，不得将此优化扩成长期内存authority。
  `pageOrder=auto` MUST 在第一次真实结构化页 materialization 前冻结：
  只有“当前漫画为单章 + verified `ComicVersionPageMapping` 明确证明 pure front-prepend” MAY 冻结为 `chronological`，
  否则 MUST 冻结为 `origin`；来源名称/插件类型及当前页总数 MUST NOT 作为反序证据。
  结构化页号 MUST 来自 App-private SQLite 中稀疏持久的 `export_page_binding.exportOrdinal`，
  同一 logical page 的 ordinal 在普通增量更新中 MUST immutable；
  front-prepend 新页只 MAY 分配在现有最大 ordinal 之后，跨版本继承只能沿 verified compact relation 惰性查找已实际 materialized 的 anchor，
  MUST NOT 为未打开/未导出的版本预建逐页映射，也 MUST NOT 通过全局 `N-index` 重算旧文件名。
  Reader MUST 始终消费来源 logical manifest 顺序且 MUST NOT读取 `DownloadPlacement.pageOrder` 决定视觉顺序；
  只有启用 per-comic Reader 设置后的 `invertPageOrder` MAY 作为 presentation override。
  普通下载路径 MUST NOT提供隐式 `flipComicPageOrder`；
  需要改变已经可见的物理编号时 MUST 走独立显式 Export Relayout migration，并以 generation-safe 的 SQLite/物理 rename-or-materialize 提交。
  显式 overwrite 只有在 `observedOwnerKey` 精确匹配当前 owner 时 MAY 替换既有认领，模式本身不得构成宽泛覆盖许可。
  普通下载和重试 MUST NOT 枚举整个目录或收编未索引文件；每页完成时 MUST 将实际 bytes 与非空 CRC32 随 exact `CacheRec` 原子更新，重试只能消费该增量校验记录。
  未入库文件只能在显式、可取消的 chapter-file repair/audit 中扫描，或在目标提交时形成用户可处理的冲突；普通 download/retry/Reader MUST NOT 枚举目录。repair/audit MUST 由当前 download-service generation 持有取消权，并先 full-verify indexed READY；unindexed 图片只有 source-declared CRC32 与本地独立 CRC32（以及存在时的 byteLength）一致才 MAY 进入既有 artifact adoption。图片魔数、路径/page number、用户点击 repair 或本地自算 checksum 均不足以证明 exact source identity；缺少可比 source proof MUST 保持 unbound。最后一个 structural replica 被退休时，metadata owner MUST 以 zero-replica 条件事务同步撤销该 artifact 的 exact READY/physical bindings。最终目标路径写入 MUST 由唯一 artifact store 串行化；
  同一目标path的logical sibling冲突检查 MUST使用按`cache_entry.path`靶向的持久查询/索引，不得在每个page materialization内全量枚举cache bindings；
  只有现有文件与待提交内容 bytes、非空 checksum 均一致时 MAY 共享，不同内容 MUST 拒绝。
  download-cache schema 12 MUST提供该path索引，11→12升级 MUST只创建索引并推进版本，不得重跑历史artifact/backfill/identity/retention迁移。
  跨版本 createNew 复用 MUST 复制到本版本目录并在复制前后校验内容，MUST NOT 把旧版本路径登记为新版导出路径。
  结构化图片 materialization MUST 以 bounded byte signature 而非来源 hint/文件名确定最终扩展名；
  JPEG/PNG/WebP/GIF/BMP/TIFF/ICO/AVIF/HEIF MAY 被识别，ISO-BMFF MUST 以明确 brand 区分 AVIF/HEIF，
  generic `ftyp` MUST NOT 被推断为 AVIF。若结构化图片正文不匹配任何支持签名，MUST 以 `artifactCorruption` 拒绝并清理该无效 staging artifact；
  `ContentKindHint` MUST NOT 把实际非图片 bytes 认证为图片。overwrite/saveAsNew 决策 MUST 贯穿 UI、队列和存储层；
  整本执行期 `ErrorCode.policy` MUST 转为持久化 typed `requiresUserAction`，
  停止该任务后续调度并保存目录、双方 owner 与触发章节，MUST NOT 退化为可直接重试的失败字符串。详情页 MUST 强制重新展示冲突对比并在新决策形成 placement 后重建任务；
  saveAsNew MUST NOT 继承旧候选目录的 observed owner。版本关系 MUST 区分历史证据与运行时 baseline：
  `latestKnownHead` 只表示来源已确认的新候选，`shelfHead` 只来自实际采用的书架状态，`downloadHead` 只来自显式 manual-download 状态；
  发现/缓存新版 MUST NOT 自动推进后两者。
  `HomeLibrarySession`（或等价版本状态 owner）MUST 将唯一 verified 历史路径一次折叠成 direct predecessor→当前 head mapping供书架/manual/export 使用；
  Reader、下载管理、ExportLayout 与章节下载执行 MUST NOT自行遍历 `ComicVersionRelation` 多跳图。
  `downloadHead` MUST NOT限制 immutable artifact cache：
  cache/artifact owner MUST独立消费完整 source-verified relation/page-equivalence 证据，
  未显式下载的版本仍可复用既有缓存而不得仅因 head 不同重复落盘。
  下载管理手动任务 MUST 先按 `isManualDownload` 准入，再按 direct download-head mapping 归并；
  version/revision 离线删除确认 MUST 通过只读 delete-impact capability 读取当前 durable artifact/reference authority，MUST NOT 由 Widget 枚举文件、复制 `CacheRec`/artifact 引用计数或建立第二删除计划。projection 的 target MUST 与真正 `ChapterDownloadService.delete` 对该 hydrated entry 生成的 exact `DownloadId` 集合一致；同 revision 但不同 provider URI 的 historical exact carrier若不在该 entry target 中 MUST 被视为外部引用。共享判定 MUST 至少包含 target 外 exact binding 与 canonical `physical_media_artifact` binding，并按 indexed physical body/object 去重统计 bytes。projection 只用于说明预计解除的 exact bindings、受影响页、独有可回收对象与仍共享保留对象；它 MUST NOT 授权 mutation。确认后实际删除 MUST 继续经过既有 chapter command/artifact owner，并按执行时最新引用重新判定，故真实回收 MAY 少于确认快照、MUST NOT 多删快照之外仍有引用的物理对象。
  未发起的 library/Reader-cache 后继版本不得参与手动主实体选举。logical chapter 对应 MUST 使用折叠后的 `ComicVersionPageMapping`；
  有 explicit mapping 时未映射同 raw chapterId 不得猜测，只有 direct legacy baseline relation 完全缺 mapping 时 MAY兼容 same raw chapterId。
  分叉/多路径无法唯一折叠时 MUST 保持 exact version 并跳过自动复用。自动缓存 Tab MUST 以 durable physical authority 为准：
  落入当前 active verified canonical range 的共享缓存按 `VersionFamilyId + CanonicalChapterId` 合并为 Canonical 行并按 physical coordinate 只计一次；
  未验证、proof 已撤销或无法安全 canonicalize 的缓存保持 Exact 行。
  历史 exact mutable partial 只有在当前 active proof（或更强 stable media identity）可解析到 canonical physical coordinate 时 MAY 由后台 cache-residency backfill 先提交 canonical physical partial、
  再以 expected-record guard 退休未变化的 exact row；不得扫描未缓存页，gap/revoked proof MUST 保持 Exact。
  重试 MUST 严格重放当前 downloadHead 主实体自身的 placement。

新 placement 的目录、模式与 observed owner MUST 整体替换旧授权；当目录被选为 `createNew` 时，observed owner MUST 可为空，不能从旧任务继承。

- 纵向 Reader 的媒体 Presentation MUST与item-extent owner解耦：
  `ReaderVerticalGeometry` MAY决定page box与anchor，但已知source dimensions的`fitWidth`媒体 MUST独立保持source aspect，
  MUST NOT仅因父sliver box被假定精确就退化成无界`BoxFit.fill`拉伸；active-scroll真实/暂态box不匹配只能裁切/留白，不得改变媒体比例。
  Reader item extent与`MediaAspectViewport`的最终aspect authority MUST同源于physical source canvas；
  `PipelinePageStreamSnapshot` MUST只读投影`sourceCanvasWidth/sourceCanvasHeight`并由`LocalImagePlayer`优先采用。
  output/surface decoded raster MAY作为pixel carrier与provisional local尺寸，
  但MUST NOT在sourceCanvas已知后覆盖presentation aspect。
  dev.297的`<=0.5 physical pixel` bounded fill与external-texture paint snap已被设备幅度证据否证并MUST保持回滚；
  Presentation MUST继续aspect-preserving fit。
  UploadDemand membership MUST表示presentation claim/retention identity；只有`prepareOutput=true`才表示新的upload/present执行资格，`prepareOutput=false`不得清空已成功authoritative static UI projection。
  generic/network/unresolved hidden static在vertical active期间 MUST只对`far/near` speculative role defer新的native presentation work；对应UploadDemand identity MUST保留并设置`prepareOutput=false`；
  既有2/1 decode deadline窗口中的`next/next2/previous`静态一帧 MUST可在进入viewport前提前UploadDemand/present并retain output，且 MUST继续受UploadLane并发/优先级/抢占与FrameBudgeter约束，不得因此扩大2/1或3/7窗口；
  decoder已authoritative判定`animated=false`且encoded body由direct immutable local URI或`residentBodyBacked` immutable authority持有的stable static页 MAY在既有3/7 one-frame static intent envelope内提前UploadDemand/present并retain output，
  以保证进入transition前presentation-ready；
  该资格不得引入estimated static-output budget，native output residency继续由FrameBudgeter裁决，
  Flutter fallback raster residency/LRU MUST由App composition的`PipelinePresentationRasterCache`统一裁决；generic Flutter `ImageCache`仅保留非Reader图片与provider decode backend职责；
  该例外 MUST NOT创建额外DecodeDemand、扩大3/7或应用于animated/unresolved页。
  directional decode previous1/next2 policy仍是唯一decode work窗口；
  但对已经存在的authoritative static surface，Presentation MAY在该directional policy两个可能方向的并集`current±2`内跨direction flip造成的decode-plan gap保留surface/PresentClaim。
  该continuity envelope MUST只保留既有projection，MUST NOT创建DecodeDemand/UploadDemand/decode session或调用present，
  也不得改变2/1 decode policy；
  超出±2时projection claim MAY释放，但若底层UploadSession仍保留同一authoritative static OutputFrame且该exact frame已有成功presentation timing，
  后续role重入 MUST重新取得lifetime PresentClaim后直接project，MUST NOT再次调用OutputFrame.present；
  decode target/generation/identity/frame变化、真实output/upload dispose或从未成功present时仍必须走正常presentation。
  animated output MUST NOT通过该例外跨upload-demand gap保留或使用static re-projection fast path。
  对已存在Pipeline-owned surface且decoder已authoritative确认`animation.complete && frameCount<=1`的WebP，
  Presentation MAY从同一artifact的compressed bytes建立Flutter ImageProvider projection，
  但MUST保留既有UploadDemand/output/texture owner并在Flutter首帧前继续显示surface；
  projection成功只替换页面绘制，不得移除lane current、取消native output、建立第二正文cache或应用于animated WebP。
- exact durable READY 的eligible非WebP静态页 SHOULD优先消费generation-bound file/descriptor presentation lease而不是先把完整encoded body物化为Dart `Uint8List`。
  raw cache locator/PFD MUST NOT越过storage/composition owner成为持久presentation identity；
  lease交付前后 MUST校验实际`storageId + mutation generation`，stale/cancel/failure/widget retirement MUST释放lease。
  每个lease的release completion MUST保持独立可等待；
  Android presentation adapter MAY把同一event-loop内多个待释放handle合成一次native close batch，
  但 MUST关闭全部unique handles并分别完成原release Future，不得由Reader route增加固定退出等待、
  全局flush gate或改变file/ImageCache identity。
  Flutter ImageCache identity MUST独立于可复用的`/proc/self/fd/N`路径并绑定physical generation。
  WebP、Reader playback-controlled GIF、缺少可信intrinsic dimensions、
  平台不支持descriptor reopen或lease preflight失败时 MUST退回既有encoded-byte/native路径；
  该fallback MUST NOT改变3/7、decode2/1、UploadDemand、NetLane、SAF executor数量或read/open watchdog。
- 纵向 Reader 的异步 `pageAspectRatios` 更新 MUST NOT在finger-owned dragging/scrolling/settling期间改变真实visible页的extent；
  offscreen reverse prefix采用 MUST在同一次layout原子补偿，保持当前viewport prefix的top-pixel视觉anchor。
  DecodeSession已成功decode的frame可触发Pipeline提前解析尺寸，但`PipelinePageDimensionsFeed`的最终geometry fact MUST区分`sourceCanvas`与`decodedRaster`：
  source canvas优先，decoded raster仅provisional且不得覆盖source；
  dimension event MUST携带稳定`pageIndex/assetKey/width/height/basis`并由ReaderRuntime现有ratio owner消费。
  `LocalImagePlayer`从output surface取得的non-authoritative raster尺寸不得通过`onDimensionsChanged`进入Reader geometry，
  也不得覆盖已由page-stream physical sourceCanvas确立的presentation aspect。
  `PipelinePageOutputStream`与`PipelineTransferProgressPublisher` MUST通过`PipelineFrameScheduler`消费frame boundary，
  MUST NOT直接访问Flutter binding；
  Reader transfer presentation MUST订阅`PipelineTransferProgressFeed`而非Pipeline-owned`ValueNotifier`。
  沿higher-index方向，严格高于真实visibleMax的future page source ratio MAY在active scroll中提前进入layout snapshot，
  因为其extent不改变当前pixels对应prefix；沿lower-index方向，严格低于真实visibleMin的incoming source ratio MAY在active scroll中提前采用，
  但 MUST在同一次layout以提交前top-pixel anchor计算`geometryCorrectionTarget`并原子补偿prefix长度变化。
  真实visible页的新ratio通常只允许latest-wins暂存，真正idle后 MAY一次提交；
  slider scrub例外：当前已visible页的新source ratio MUST在scrub期间允许提交，并以selected current center作layout-time correction后重发coverage，
  从而避免unknown一屏provisional extent与transientPreview hidden gate互相等待；该例外 MUST NOT赋予原hidden页执行资格，只有新geometry确认其真实可见后才按既有visible规则晋升。
  MUST NOT恢复dev.207 ratio-driven `jumpTo`循环，也 MUST NOT恢复dev.286 `presentationExtentAt`/OverflowBox裁切workaround。
  真实viewport/DPR/stitch变化与显式navigation仍 MAY保留/恢复anchor。
- 纵向 page-host composition retention MUST 与Pipeline资源窗口分离；
  production仅保留nominal `current±7` AutomaticKeepAlive。
  不得恢复已被dev.285设备证据否证并回滚的dev.284 mount-travel keepAlive guard，也不得用扩大`cacheExtent`替代真实布局/资源根因分析。
  对vertical continuous，current±7半径不变且keepAlive center MUST在一次active scroll内冻结；
  普通ScrollEnd/idle recenter MUST跨frame有界迁移，不能一次跳变而同步释放整组旧window host；
  显式navigation/direction change MAY直接提交目标center。
  不得恢复dev.284 expanding travel-union guard，也不得因current每跨页同步demote远端host。

## 10. 插件与来源

- 插件 MUST 在隔离、信任和权限门禁内执行，只返回 catalog 数据、request plan 或显式有界 transform 结果。
- runtime adapter MUST独立校验实际响应的 `maxResponseBytes`，不得仅信任backend声明。字符串键和值的预算按UTF-8计数，合法surrogate pair为4字节、孤立surrogate按U+FFFD为3字节；计数 MUST NOT物化完整encoded bytes，depth/type与binary/scalar合同保持。
- 普通图片正文 SHOULD 由宿主 transport 流式下载。平台 transport MAY 将底层网络小包聚合为面向 Pipeline 的较大逻辑块，以降低 Dart 调度/commit 开销；
  首播块 SHOULD 小于持续传输块，聚合不得改变字节顺序、取消、Range/validator、artifact或重试所有权。
  `IoTransport`/平台 transport MUST保持通用 byte transport，不得拥有 image classifier、`ContentKind` 或 semantic retry。production composition 的 image physical transfer MUST在 `DownloadJob` admission 消费当前 `DownloadSession` generation-local bounded metadata prefix，并用共享 supported encoded-image signature classifier 验证新 source/local-transfer generation；prefix 达到 sniff 上限仍不匹配，或短 final body 结束仍不匹配时 MUST产生 `ErrorCode.source + sourceMediaSemanticRejected`，且新正文 MUST在 seal/promotion/READY authority 之前失败。`DownloadTransferOwner` MUST让 local-prepare completion、NetLane 前 local completion 与 source/network resident completion 共享该 gate，并在 terminal semantic rejection 后删除被拒 generation 的 partial/final authority再发布 failure。已经由 durable `artifactCache` 持有的 resident generation MUST继续交给既有 storageId+generation-aware presentation recovery；sessions 不得在缺少 cache-generation proof 时把普通 response rejection升级成 durable cache invalidation。合法 JPEG/PNG/WebP/GIF/BMP/TIFF/ICO/AVIF/HEIF正文 MAY继续按既有 `fallback/webp/gif` 分类；opaque URI、扩展名和 Content-Type MUST NOT单独决定准入。
- 插件不得访问导航、Reader、demand、artifact、App state 或底层缓存。
- Cookie、token、脚本 payload 和 Base64 正文不得原样写入 Trace。
- durable handoff 后已安装插件恢复 MAY 对互不相关的 runtime 使用最多 4 个并发激活 worker；
  registry MUST 只串行化最终 session 的短状态提交，并在提交边界重新检查 source identity collision，慢候选不得阻塞先完成的候选。
  manifest 已保存的插件元数据 MAY 跳过重复 Dart inspection/hash，但隔离 runtime 在加载前 MUST 重新验证 payload byte length 与 SHA-256；
  设备 Mihon 扫描 MAY 与已安装插件激活并行。漫画源页底部控件 MUST 只投影已经产生活跃 source session 的插件；
  已安装但未启用/激活的 Mihon/Venera MUST 只留在管理页，不得显示 disabled 来源控件。
  不可恢复的 typed denial/完整性错误 MUST 回滚新记录并删除新 payload，可恢复失败 MUST 保留记录和 payload并允许从管理页重试；
  replacement 失败 MUST 保留旧 session。漫画源管理页返回 MUST NOT 等待后台库 projection reload。
- Venera MUST 保持单 WebView、单 invocation 生命周期。
  可能等待 origin 的 `Network.*` MUST 通过异步 native callback bridge执行，不得阻塞 WebView JavascriptInterface 线程；
  激活 MUST 只等待源代码显式 `await` 的初始化工作，激活期间未等待的后台工作 MUST 在下一次 invocation 前由 runtime-owned gate追平。
  取消 MUST 继续沿 `requestId` 贯穿 JavaScript、native transport 与 rhttp；
  runtime close MUST 取消未完成的 bridge transport，scheduler permit 只能在真实 invocation 结束后释放。
  rhttp client warm-up MAY 在 runtime service ready 前执行，但不得把网络路径延迟伪装成设备/CPU加载性能。
  Venera canonical source WebView MUST 继续保持单 stateful invocation context；
  实现不得仅为 `modifyImage` 吞吐把整个 source runtime 并发度调高。
  source 明确返回、且静态/动态资格均证明不读取 `onResponse`、source/global/browser/network 可变状态的纯 `modifyImage` MAY进入独立 image-only execution plane；
  该 plane MUST不加载 source script，MUST只暴露 `Image` primitive，
  MUST不暴露 `Network`、Cookie、settings、source data 或其它 browser state。
  image-only plane MAY 有界并行最多 2 个 transform；每个并行 worker MUST 独占 WebView 与 Bitmap namespace，
  MUST NOT共享 request-local image handle 或 `disposeAll`。Dart transform admission 与 native worker capacity MUST保持同一上限，
  MUST NOT再建立独立 FIFO queue/scheduler。
  isolated输出编码 MUST NOT阻塞共享JavascriptInterface线程，MAY借用既有native host executor；MUST NOT新增池或扩大已接纳transform容量。
  JS MUST等待编码物理退出回执才disposeAll/finished；取消 MUST保持worker容量到该退出边界，close MUST先drain编码再回收Bitmap。
  编码失败或executor拒绝 MUST经原completion/finished链一次性收敛；迟到正文token MUST交回原body owner清理，transform MUST NOT关闭借用的executor。
  资格失败或运行时发现缺失 source global MUST返回 incompatible 并重新经过 canonical source gate；
  `onResponse` MUST始终只在 canonical context 执行。
  image-only plane 不得在其 transform gate 内调用 canonical WebView，也不得成为第二 source-state owner。

## 11. Telemetry

纵排 `readerFrameTiming` MAY按约1秒摘要真正普通帧并保留样本数及各 timing/frame-interval min/max；
build/raster/total span达到16.667ms或frame interval达到20ms的异常样本 MUST逐条保留且不得跨异常帧合并摘要。
interval hole即使Flutter work较小也属于待归因证据，独立scroll/platform cadence observer用于补充归因而不是替代原始异常序列。
纵排 `cacheExtent`/keepAlive MAY保留 viewport 外 page subtree 以承载预加载与快速回访，
但该 residency MUST NOT自动取得 Flutter frame/ticker 权限：
Reader MUST以其现有 geometry `visibleCoverages` 的真实可见 index range 控制 subtree `TickerMode`；
不可见 subtree中的 indeterminate loading/progress/animation MUST被 muted，
同时 source/cache/decode/presentation async work MUST继续推进。
该 gate MUST NOT缩小encoded/decode/upload window、改变current/transition语义或影响paged Reader。

Trace MUST 记录 demand/session/writer/source/decode/upload/present/retry/lifecycle 的可归因摘要。
App preferences MUST提供独立Debug模式总门；
默认保持开启以兼容既有诊断工作流，用户关闭后Home/Misc等Debug/Trace/媒体诊断入口 MUST不参与widget tree，Debug Trace sink MUST停止记录；
普通用户可见错误、复制技术错误与非Debug业务入口不得因此消失。内部`debugTraceEnabled` MAY在Debug模式开启时继续控制是否实际记录。
Native Animated WebP decode MAY附带prepare/canvas/fragment/composite/frame-copy分段、
OS thread id、CPU start/end/allowed mask与bounded frame-structure统计；
这些字段 MUST observation-only，MUST NOT驱动waterline、worker placement、
DecodeTarget、transport、presentation或CPU-affinity策略。
Debug Trace 文件导出 MUST 由单一 App export service 负责事件 snapshot、JSONL 编码、文件命名和目标目录；
首页快捷导出与 Trace 页筛选导出只能选择事件集合，不得各自实现第二套写盘逻辑。Android 默认写入公共 `Download/Debug/`，用户可配置 `Download/` 下的相对子目录；
该偏好 MUST 由同一目录规范化规则持久化，native 仅做最终越界/无效路径复验。
composition physical transfer对同一共享App/export TraceSink的同一事件 MUST 只投递一次；
生产Pipeline MUST NOT保留无显式读取方、无容量上限的Reader-local全量memory副本。
测试/工具若需要`MemoryTraceSink` MAY显式选择有界容量，但多个Reader不得放大全局导出次数。
前若干不同帧 SHOULD 保留逐帧 timing，至少区分 lane queue、source wait、
cursor/worker/native decode、upload backpressure、output prepare、
platform/schedule queue、blit/replace和 channel dispatch。
纵排抖动诊断 MAY 以有界低频`pageLayoutSnapshot`记录真实可见page RenderBox的expected extent、
constraints/size、paint/global rect、transform、role与interaction；
post-frame RenderBox若与scroll position做残差比较，MUST使用同一post-frame时点的live scroll pixels，
不得混用调度采样时的旧pixels制造伪layout residual。该事件 MUST 只用于归因，MUST NOT 成为layout、navigation、presentation或scheduler输入。
纵排Reader MAY记录真实Flutter `readerFrameTiming`（build/raster/total span、vsync interval）以诊断整帧cadence；
Flutter timing callback可批量返回历史frames，因此Reader MUST NOT把callback时刻的scroll/current/interaction伪装成每个历史frame的逐帧上下文，
SHOULD记录batch index/size、callback monotonic与last-vsync anchor供时间轴重建。
Flutter `SchedulerBinding`/`dart:ui FrameTiming`/`FramePhase` MUST由`reader_runtime` presentation adapter归一化成框架无关`ReaderFrameTimingSample`后再交给Reader，
`ReaderView` MUST NOT直接解析engine timing API；该事件同样只用于归因，MUST NOT驱动任何Reader/Pipeline状态。
accepted plan MAY另记录`pipelineReconcileTiming`（reconcile时长与download/decode/upload diff cardinality）以验证控制面事务成本；
该事件 MUST只写入Trace，MUST NOT因自身记录请求Flutter frame或成为调度输入。
Existing identity的scheduling-only role/priority migration MUST由plan/reconcile级诊断归因，
不得为每个已存在download/decode/upload重新制造lifecycle demand Trace；
Reader ingress/source-watch MUST只在新identity或physical DownloadSession对象真实更换时建立/重绑。
physical claim若仅reason/priority/flow target变化 MAY原位更新scheduler state，
但exact identity、checksum proof或completion intent任一变化时 MUST回到完整claim establishment。
vertical Reader MAY记录非零位移且相邻原始ScrollUpdate间隔>20ms的`scrollCadenceOutlier`；
该诊断 MUST NOT schedule Flutter debug frame、改变ScrollPosition或驱动任何policy。
`dragDetails!=null`的ScrollUpdate MUST保留drag-driven语义并在outlier记录`dragDriven=true`。
dev.310 ballistic证据仍要求touch sampling不得被用来解释post-lift cadence hole；ADR 0325的独立healthy-cadence displacement A/B只重新打开finger-down drag。
仅`reader_runtime` MAY在vertical continuous Reader生命周期通过ref-counted lease启用`GestureBinding.resamplingEnabled`并在最终release恢复旧值；`reader` MUST NOT持该framework state。
生产代码 MUST NOT调整`samplingOffset`、自定义插值位置、强制frame或更改ScrollPhysics。vertical Reader 的Android主动cadence诊断 MUST默认关闭；
只有显式诊断构建 `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true` MAY由`reader_runtime`启用Android `android.view.Choreographer` observation-only probe。
该probe逐vsync自续订并非零成本被动观测，常规静态阅读 MUST NOT为它维持callback、Window metrics listener或2s drain；
关闭不影响被动Flutter timing、加载/任务Trace或资源调度。启用时：
native记录>=20ms frame/callback gap或>=8ms callback lag到bounded 256 ring，
并可附main-thread CPU delta/display refresh；
同时MAY在native端聚合全部frame interval到固定cadence bins，Dart SHOULD以>=2s低频drain映射为`platformFrameCadenceOutlier`与`platformFrameCadenceSummary`。
probe MUST NOT schedule Flutter frame、改变Reader/Pipeline状态、请求frame rate、切换touch boost或改变资源策略。
dev.312的ARR policy已由dev.313证据排除为共同根因，production vertical Reader MUST NOT自动启用该Window行为干预；
若未来重新做platform frame-rate A/B，必须作为独立、显式、可恢复的实验边界。
vertical Reader MAY另以约1秒有界`scrollCadenceSummary`聚合所有非零位移ScrollUpdate interval到固定bins，
用于区分engine frame cadence与实际motion update cadence；summary MUST observation-only、不得请求debug frame或参与policy。
当Flutter Build/Layout/Paint/raster很小但cadence仍有hole时，
`reader_runtime` MAY在vertical probe生命周期使用Android API24+ Window `FrameMetrics`纯观测total/unknown delay/input/animation/layout/draw/sync/command-issue/swap，
并在API26+记录intended/actual vsync；listener MUST使用独立HandlerThread、bounded ring与低频drain，
重复vsync MUST去重且summary SHOULD记录first/last vsync以显化coverage，
`platformWindowFrameMetricsOutlier/Summary`不得请求frame或驱动Reader/Pipeline。
listener第三参数 MUST命名/解释为`droppedReports`（metrics report loss），不得冒充display dropped frames；
Window metrics不得无证据视为Flutter SurfaceView内容帧的连续代理。
离线Perfetto验收 MUST核对当前buffer/parser完整性与ZIC SurfaceView内容层覆盖；
`traced_buf_chunks_discarded`表示本次buffer丢弃，service lifetime的`traced_chunks_discarded` MUST NOT单独使本次trace失效。
缺少内容层FrameTimeline时，同次输入/Reader motion关联的精确`SurfaceFlinger --latency` MAY作为限定窗口的呈现cadence证据，
MUST NOT据此声称composition、触摸延迟或固定位置视觉顿挫验收通过。
仅显式`ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true`的诊断构建中，vertical Reader MAY在active scroll期间递归注册不调度新frame的post-frame callback，
读取同一frame完成后的live scroll pixels与current page RenderBox，
聚合`globalTop + pixels - expectedStart`残差连续性为`verticalSceneMotionSummary/Outlier`；
该probe MUST不调用scheduleFrame、setState、jump/animateTo或成为policy输入；普通构建 MUST不注册该scene-motion probe。
vertical active motion中canonical desired encoded window MUST继续是forward7/backward3；
为避免confirmed direction flip把far speculative membership一次性5/5翻面，accepted physical download plan MAY使用有界bridge：
所有desired DecodeDemand/UploadDemand以及current/transition所依赖DownloadId MUST立即存在，
encoded-only new desired membership每个新committed current最多迁入1个，
previous speculative DownloadDemand MAY在guard总数上限内暂时保留；bridge MUST NOT减少mandatory source、增加download count、
改变decode2/1/upload role/current semantics或使用时间debounce，idle/scrub/jump MUST完全收敛canonical desired 7/3。
`TraceEvent` payload MUST在进入bounded ring时归一化为JSON-safe值，单条producer对象不得毒死整份导出。
`scopeId/physicalMediaKey/providerExactId/candidatePhysicalKeys`中的长或opaque组合键 MUST按完整原值生成稳定hash与原长度摘要，MUST NOT让provider子串正则吞入相邻字段长度；候选列表、嵌套map及重复归一化 MUST保持关联与隐私。此诊断token MUST NOT参与缓存身份、URI、信任或调度决策（ADR0384）。
任何把原始异常/Failure技术细节呈现给用户的错误面 MUST至少满足“写入可归因Trace”或“可直接复制完整错误”之一；Reader章节加载和图片终局错误 SHOULD同时满足两者。

所有需要跨组件比较/排序的 `TraceEvent.monotonicMicros` MUST使用同一 process-monotonic clock epoch；
route-local stopwatch MAY计算duration但 MUST NOT写入跨 Home/Details/SourceBrowser/Reader/Pipeline 的事件时间轴。
physical DownloadSession 的trace identity MUST跟随其physical owner而非exact provider anchor；
decode/upload等重复事件 MAY由owner缓存一次与`TraceEvent`脱敏结果完全一致的稳定identity token，
但该token MUST NOT替代 lane/task/cache 的逻辑identity。identity 超限时使用稳定 hash 与原长度；
locator脱敏pattern MUST复用且普通非locator字符串 SHOULD在进入正则前廉价跳过。
高频事件 MAY 在导出投影按语义分桶合并，但UI/export容量淘汰 MUST为O(1)，bucket索引 MUST随对应entry淘汰，
数值range合并 SHOULD只遍历当前事件实际存在的allowlisted字段。
`framePipelineTiming` 的合并 MUST 至少区分 trace reason、dominant stage 与角色，
`decodeRefill` 的合并 MUST 至少区分 role、stage 与 source-wake，
并保留 first/last、coalesced count 以及关键 timing/source length/revision 的 min/max；
错误和生命周期边缘、retry/resume、`sourceRead` 与网络任务边缘 MUST 保留。没有Trace UI listener时记录事件 MUST NOT请求Flutter frame。
Trace 不得成为业务状态权威来源，导出压缩 MUST NOT 驱动调度、重试或缓存，overlapping total 不得与子阶段重复参与 dominant 归因。
Android来源正文阶段系统采集 MUST仅观测原client、stream与claim，不含URI/Cookie/header/raw requestId；关闭采集 MUST直接使用原stream，不改变取消、调度、缓存或源请求语义。

正常 platform present 的逐帧 Trace MAY 省略重复投影，但 startup/stall 与 20ms 以上 platform 异常仍 MUST 可归因。

## 12. 测试与发布

- owner test MUST 位于实现所属 package；App 测试不得导入低层 `src/` 或重复低层算法。
- 异步测试 MUST 使用可控 Future、状态对象或稳定 key，不得固定 pump 猜测完成。
- quarantine MUST 有稳定 ID、原因、仍运行的 owner 覆盖和解除条件。

发布候选 MUST 尽可能完成 analyzer、受影响 package/App tests、native tests、
Android debug/release、Mihon/Venera/Android 合同、干净 ZIP 独立复验，并排除 `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、
`target`、`__pycache__`、`.pyc`、`.class`、`.rej` 和 `.orig`。未执行项 MUST 在 Status/audit 标为 Unverified。

## Artwork 与插件会话稳定性要求

1. 失败封面不得因父组件 rebuild、App resume、timer/watchdog或第二个 ImageStream自动重新发起请求；
   Presentation MUST 保持稳定占位，只有显式来源刷新、资源 revision或稳定 identity变化才允许重新加载。
   漫画源显式刷新 MUST 将当前来源已观察的 decode失败作为一次性精确 artwork刷新命令传至 gateway，
   在原 canonical cache key 上重新获取；MUST NOT清空健康封面或其它来源缓存。
   catalog刷新 MUST保留健康和仍在等待的封面 Future及既有Image State；只重试同来源当前 Future的已观察 source/decode失败，不能因刷新metadata重新获取全部封面。
   迟到的旧 Future 回调 MUST NOT污染当前刷新意图，旧 Image State的错误 MUST NOT被归给不同 provider的新资源。
2. 实际预览行含横图时 MUST 最多 2 项，纯竖图行 MUST 最多 3 项；为满足该规则 MAY 在相邻三个候选内做一次最小局部重排，并受用户设置的更小上限约束；不得用额外间隔消耗剩余宽度。
3. 详情与漫画源下拉刷新 MUST 共用同一个组件拥有 edge trigger、位移、刷新进度和成功/失败反馈；结果图标 MUST 与刷新指示器使用同一落点。

4. encoded artwork source 已就绪后，普通 artwork MUST 只创建一个 ImageProvider/解码监听；
   需要裁剪或尺寸测量的 Presentation MAY 显式监听一个 ImageStream并直接绘制 decoded image，但 MUST NOT 同时构建第二个 `Image`监听同一 provider。
5. 远程详情 MUST 先显示已有 catalog/detail cache，并等待当前 active source adapter 完成后台刷新；
   主详情、章节、预览和评论 MUST 按元数据类别增量替换，预览、评论及章节操作 MUST 在调用时解析当前 adapter，不得持有插件重启前的关闭 session。
   详情 route 的首帧 MUST 不依赖下载状态/artifact I/O 或跨版本 page proof，且详情生命周期 MUST NOT仅因存在版本入口而启动page-mapping媒体预热。
   已持久化的同源 successor/predecessor MUST 先于网络发现投影，网络只在后台校准；
   版本入口 MUST 与“下载整本”保持同行且使用固定占位，无版本关系/加载中不绘制图标，不得迟到插入整块 UI 改变布局。面板 MUST 在同一层切换新/旧版，标题点击直接查看详情，行尾迁移直接进入对比；
   列表 MUST 显示可读标题和日期，MUST NOT 显示 opaque ID 或 source 伪 generation。
   正文喜欢、书架、收藏和下载 MUST 保持统一 48×48 `_PreferenceButton` 尺寸，不得因不可见版本槽整体缩小。
   版本入口 MUST 位于顶部 AppBar“迁移漫画源”控件左侧并复用标准 `IconButton` 风格；无关系时仅保留标准 action 空槽。
   缓存首显后的 source refresh MUST 更新当前 route/面板。“迁移到当前版本”只在存在非当前 canonical predecessor 时可用，并 MUST 进入迁移对比。
   同源替换对已验证等价的 durable source artifact MUST 物化为目标 exact DownloadId，确保移除旧记录或重启后仍不重新下载；未验证页面 MUST NOT 复用。
6. Mihon chapter catalog MUST 只投影插件/source API实际返回的完整 `SChapter` 列表。
   漫画输入 MUST接受完整`mihon:manga:`模型或插件原生`SManga.url`；原生输入只提供原文URL与空初始标题，其余元数据/目录仍由source返回。保留的`mihon:`身份 MUST按kind严格校验，不得将损坏或章节/资源identity当原生URL。
   调用及返回漫画/章节父身份 MUST保留调用者的原始comicId；相同source URL的两种输入 MUST共用目录互斥与canonical artwork namespace，UI不得包装opaque ID或猜测站点路径。
   完整目录响应缓存 MUST按raw请求comicId区分，因为其漫画/章节父身份属于该请求；同源别名仍 MUST共用canonical namespace进行metadata失效，MUST NOT失效健康artwork或用另一别名manifest改写历史/下载身份。
   source对象和newest-first列表 MUST原样保存；opaque章节ID内source ordinal MUST保持identity兼容，向外sequence MUST投影为oldest-first逻辑序号，旧持久目录MUST通过同一source合同适配而不得重写下载ID。
   Reader当前章定位 MUST优先exact ID；同source/comic内 MAY以唯一完整source model一致性处理host ordinal/parent locator变化。URL单独或歧义匹配 MUST NOT作为定位proof，逻辑定位 MUST NOT授权page复用或改写ID。
   只读详情 MAY将同source/comic的既存metadata投影到唯一完整source model对应的当前章节行，MUST以快照实际章节作用域保留历史进度/手动已读且不重复计数，不以route别名过滤；歧义、模型变化及跨scope MUST NOT归并。
   显示投影 MAY消费紧凑Home快照中的已存页数，MUST NOT据此授权占位正文复用或改变预览跳章的页数裁决。MUST NOT改变source catalog、持久ID或下载/删除/已读写入身份；继续阅读 MUST保持真实历史记录入口。
   同source+canonical漫画URL的getMangaUpdate MUST在runtime owner内互斥且等待可取消；不同漫画不得受全局FIFO阻塞。active取消回执MUST等待真实调用退出；无可取消context的suspend调用MUST先drain continuation再释放互斥与runtime completion。
   TachiyomiX 1.6/current Mihon MUST 先调用 `getMangaUpdate(manga, existingChapters, ..., fetchChapters=true)`；
   只有 combined能力明确不存在时 MAY回退 legacy `fetchMangaDetails/fetchChapterList`。
   正文 MUST先调用 `getPageList(SChapter)`，只有能力不存在时 MAY回退 `fetchPageList`。成功空列表是合法结果；真实调用错误保持失败。
   MUST NOT 从 manga URL生成兼容单章，也不得按标题、`SChapter.url`、number或sequence推断、增加、删除或合并章节。
7. Reader progress 的有序性与 durable I/O MUST 解耦：SQLite实现 MUST 在非 UI isolate执行同步 sqlite3/章节校验；
   普通 Reader 页面变化只入队 latest checkpoint，不得逐页发布 Home/library projection或等待 durable I/O。
   普通Reader页码变化 MUST NOT 等待durable barrier；逐页交互不得串行到durable写入。
   正常route-pop checkpoint flush与app lifecycle flush MUST作为明确durability barrier排空已接纳checkpoint；失败 MAY记录并允许退出，不能伪称durable success。
   barrier 后 Home/详情与下一次 Reader hydrate MUST 通过 store-owned targeted progress authority 合并最新值，
   manifest/version hydration cache 只缓存章节/page authority，MUST NOT 回滚 mutable progress。
8. 外部 artwork MUST 统一通过 `ComicSourceResourceGateway`；
   raw plugin comic locator 与 durable artwork identity MUST 分离。
   Mihon 等可变 raw locator必须使用 source canonical comic identity构造封面/预览 cache namespace；
   `mihon:resource:` 等插件 URI不得传给本地文件 loader。
9. 同一 browser snapshot revision MUST NOT 在每个 HTTP 请求前重复覆盖 runtime Cookie；新 revision可再次导入。
   Mihon首个重试 MUST能从 snapshot同步获得 cookie，不得依赖 Android `CookieManager.setCookie()` 的异步持久化时序。
10. retryable runtime lifecycle envelope MAY 自动重新激活并重试一次；
    业务错误和 `source-verification-required` MUST NOT 被当作 runtime崩溃吞掉。
11. Mihon/外部插件同 pluginId 的 runtime restart或更新 MUST 使用事务式 replacement：
    候选 session先完成 activation、source identity/ABI等验证，成功后才能替换当前 source owner并关闭旧 session；候选失败 MUST 保留旧 session。
    不得先 deactivate再尝试 activate。
12. Mihon `imageRequest(page)`（或等价 source request）的 URL、
    method、headers与必要 request body MUST 原样进入 `ComicResourceRequest`；GET/HEAD body MUST 为 null。
    宿主直连 MAY补 source OkHttp CookieJar的当前 Cookie与 browser-session UA，但不得把普通图片完整 body路由回插件 JSON/Base64 RPC。
    HTTP响应Cookie MUST保留domain/name/path身份及Secure、host-only和有效期，只发送未过期且匹配请求URL的Cookie；同名不同path MUST独立保留并优先发送长path。
    异步CookieManager镜像 MUST NOT恢复请求domain/path范围内已知的过期/删除Cookie或扩大已知Secure范围；另一path的同名响应Cookie MUST NOT屏蔽请求URL上的未知镜像Cookie。既有浏览器快照revision/UA交接保持在原network bridge适配器；镜像header没有属性，同名且范围重叠的未知身份仍无法完整还原。
    canonical default-client的三类精确拦截器 MUST被host capability判定视为可重放；source-loader所属/未知拦截器 MUST继续使用runtime兼容路径。
    该判定 MUST NOT扩大到整个interceptor包或关闭redirect、Set-Cookie、非媒体prefix的source recovery边界。
    installed payload authority 比较 MUST只作用于携带完整v3 SHA-256后缀的runtime-transform章节。
    有效的普通HTTP/replay-capable章节 MUST NOT因没有该后缀而被强制刷新或拒绝；legacy locator与快照占位页 MUST继续刷新。
- 同源版本媒体复用 MUST 将强identity/offset验证收敛为当前chapter的bounded preparation并持久化chapter mapping。
  详情/version-state发现relation后 SHOULD异步warm实际有缓存状态的当前chapter；
  普通Reader route只消费本地mapping并立即进入Pipeline，MUST NOT为generic历史relation同步做source proof。
  用户显式“查看同源版本”时 MUST由 version-reuse lifecycle 持有selected target context（`originComicId + reuse-preparation Future`），
  UI route 只负责在 push 前开始、在 finally 精确释放；不能因前置Future完成而提前清除。若用户随后进入目标Reader，Reader MUST在创建physical demand前先等待该Future，
  再以已经hydrate的目标chapter仅针对`origin ↔ target` direct relation做一次target-side bounded catch-up并发布canonical projection。
  该barrier只属于显式selected version，MUST NOT扩成generic Reader同步proof或同漫画全历史批量probe；
  目标版本独有/未验证页继续exact-only，只有verified projection区间可直接落到canonical physical owner。
  selected relation若是旧proof模型 MAY按持久`intervalProbeVersion`只升级一次；
  generic后台已有chapter/pageCount/sourceRevision匹配且anchor proof非空时直接复用。
  Reader开始后 MUST异步并行刷新当前chapter metadata与source version relation；
  新mapping/新existing-state完成后 SHOULD立即登记等价页供尚未acquire的后续demand使用，但不得late-merge已创建physical session。
  source-card版本提醒 MUST区分relation predecessor与successor的raw/canonical identity。
  partial只允许复用已持久化、inactive且mapping已验证的前缀；版本warmup/Reader入口 MUST NOT预先复制cross-version partial到目标exact key。
  recoverable session-local artifact MUST继续优先于durable store；
  仅在该physical generation没有可恢复session-local body时，physical prepare的durable tier MUST把exact与direct verified-equivalent READY/partial作为同一candidate set：
  完整READY MUST优先于incomplete partial，incomplete partial SHOULD选择最长可用prefix，同一authority等级且长度相同时 MUST优先exact。
  若durable store暴露cheap partial metadata，候选state/length MAY先用于排序以避免逐候选body preflight，
  但最终被选中的candidate MUST再次通过原`openPartialDownload()`物理校验，
  metadata/open发生变化 MUST回退exact+verified-equivalent完整physical scan。
  跨版本ETag/Last-Modified MUST丢弃，续传仍 MUST通过validatorless overlap字节验证。
  durable partial lookup MUST保持在异步physical prepare边界，MUST NOT把存储I/O塞入同步Reader demand planning；
  durable partial existence/read MUST由persistent index/file authority直接解析，
  hit/miss MUST NOT通过session registry `get()`或`DownloadSession.restore()` materialize synthetic durable-store session；
  只有durable mutation MAY使用store内部session/writer；
  该local prepare MUST在NetLane transport/source admission之前由physical owner single-flight执行，
  MUST NOT等待network lease才开始hydrate；local prepare完成顺序 MUST NOT定义network task创建顺序；
  完成后physical owner MUST按当前`DownloadSession.effectivePriority`保持local→network rank连续性，
  lower-priority ready work不得越过仍在prepare的higher-priority demanded work，随后才交给唯一NetLane；
  cold partial durable read MUST与artifact-cache replay共用composition `ArtifactCacheReadScheduler`并按chunk/dynamic priority调度，
  MUST NOT因3/7前移创建无界本地read并发或第二local scheduler。
  prepare期间的demand revision只更新claims，完成后 MUST重新解析当前preferred claim；
  若local prepare失败 SHOULD单次降级到provider path而不得形成cold-store retry loop。
  跨版本已经各自创建的independent hot physical session MUST保持各自单writer且不得事后merge；
  新exact identity在session创建前若有direct verified proof命中existing physical authority，
  则 MAY通过acquire-time alias共享一个既有hot physical transfer；
  若同时命中多个owner，MUST优先promoted，其次active writer/run、demanded、
  可恢复committed partial，并以committed length、demand/priority和稳定identity作确定性择优，
  MUST NOT因ambiguity创建新的第三physical session。

13. 仅在 Reader 中缓存/流式播放的页面未进入离线存储时不得判定为 fixed/pinned，避免未手动下载的章节流入「手动下载任务」。
    Reader 页面准入与跳页 reconcile 过程中，`DownloadSession` 恢复缓存元数据期间 MUST 允许 attachDemand 与 attachIngressProjection，
    不得抛出 sessionBusy 中断 observation 调度。
14. 同源多版本等价映射在验证成功后其页码偏移在本地数据库中永久有效；首尾 2 锚点结合逆序判定开头补图（尾部对齐）或尾部追加，禁止循环全量向插件发起逐页探查阻塞运行时。
    内存维护已恢复目标集合（`_restoredTargets`）防止重复解析。
    `PersistentDownloadArtifactStore` 在分配下载目录时，若磁盘实际不存在且无活跃任务，优先使用标准纯漫画标题目录名，绝不在无冲突时误加来源后缀；
    读取层通过磁盘物理文件名换算页码与 Key 映射直接流式打开物理文件，避免破坏性目录搬移与跨文件系统重复复制。
15. 内存与存储层之间的 Promoted Artifact 提交与持久化 Handoff MUST 使用零拷贝不可变视图（`UnmodifiableUint8ListView`），
    禁止对已不可变的数据反复执行全量堆内存深拷贝（`Uint8List.fromList`）；对已有权威校验和的媒体块 MUST 透传 contentHash，避免重复逐字节哈希重算。
16. 物理 `DownloadSession` 的 local preparation MUST 只承担有界 operation 生命周期与动态 priority 排序，
    MUST NOT 根据 `PageRole` 或 `priority>=900` 再建立第二套页面资格门禁。composition 级 local prepare 普通同时最多 2 个；
    唯一的额外 admission 是 visible-cohort handoff：当且仅当普通2槽已满，pending candidate 与两个active work
    属于同一Reader consumer、同一accepted demand revision，三者effective work mode均为`localOnly`且
    `DownloadDemand.viewportVisible=true`时，physical owner MAY让该第三个operation短暂重叠；
    handoff MUST最多1个，任何第四个operation、跨consumer/revision、hidden或非localOnly work MUST继续等待普通slot。
    `DownloadDemand.viewportVisible` MUST由当前Reader observation的真实`visibleCoverages`/current事实产生并由LiveCoordinator原样投影，
    MUST NOT由transfer owner从页号、drag direction或PageRole猜测。
    该handoff只改变local operation lifetime，不得扩大7/3 membership、2/1 decode deadline、Upload/presentation并发、
    raster预算或NetLane容量，且`localOnly`仍MUST NOT打开remote source；
    该 operation cap MUST NOT 变成不可抢占的 pre-admission 阻塞：
    当所有 operation slot 已占用且一个新的 high-priority demanded preparation 被阻塞时，
    physical owner MAY复用唯一 NetLane 的数值 high-priority/preemption margin 与同一 preemption-candidate grace；
    只有该 high-rank candidate 稳定越过 grace 后才可取消至多一个明显更低 rank 的 active local preparation，
    candidate/victim 改变 MUST重置 grace，且一次只能有一个该类 cancellation in-flight。
    上述 grace 只适用于仍拥有 local/full execution permission 的相对 priority 抢占；当 physical effective work mode 降为 `retained` 时，
    local preparation 的执行资格已经被撤销，owner MUST立即向 pending/active preparation 发 cancellation，不得让 priority=0 的旧 scrub restore继续占 slot。
    claim 新增、更新、移除 MUST复用同一个aggregate execution-permission投影；最后一个local/full claim被移除而retained claim仍在时，`DownloadSession.demanded`仍可保持true，但 MUST NOT因此保留local execution。
    取消 MUST等待旧 writer/descriptor/operation Future 实际退出后才释放 operation slot，
    普通路径 MUST NOT让并发数瞬时超过 2，visible-cohort handoff 活跃时 MUST NOT超过3，
    且均 MUST NOT删除 durable partial 或撤销 logical demand；
    scheduler-owned local preparation若已进入generic `Artifact.restore`/whole-file CRC，
    现有`TaskControl` MUST继续下沉到该restore；
    受控CRC MUST保持off-UI且cancel必须终止其worker并及时释放operation slot，普通restore/seal的非受控CRC语义不得改变；
    0-byte victim MUST重新进入正常 local preparation，已复制 prefix 的 victim MUST进入既有 post-local network admission rank barrier，
    而不得绕过仍在 local prepare 的更高 priority work。
    persistent partial/artifact 的真实 body I/O MUST 继续由共享 `ArtifactCacheReadScheduler` 逐 chunk 重新 acquire，
    并在 foreground 压力下按该资源 owner 的 bounded background quantum 让权。
    若 pending local-read request 的 scheduler-owned control 实现 `PriorityObservableTaskControl`，
    其 priority 变化 MUST 立即唤醒 `ArtifactCacheReadScheduler` 重新评估 pending 排序/准入；
    后台页在已排队期间提升为 transition/current 不得等待无关 local I/O 自然完成才获得一次重新仲裁。
    该通知只拥有 pending wake/reorder，MUST NOT取消、重开或替换已经 admitted 的 physical read，也 MUST NOT形成第二 local scheduler。
    非 resident WebP 的既有本地字节向 Reader Ingress 重放 MUST 保持渐进 prefix/suffix 语义，不得在 sourceReady 前强制整页 materialize；
    `DownloadJob.completeWithoutTransport` 对已验证 promoted metadata MAY 使用 `verifyPromotedChecksum:false` 避免重复 whole-file CRC。
    Pipeline 的 7/3 download window、2/1 deep animated media window、
    static one-frame intent 与 staged decode waterline 仍是页面扩张的唯一 policy authority；
    local prepare/transport层不得复制这些资格。
17. Reader-local encoded source MUST 由 media ownership 驱动，
    而不是由宽 `DownloadDemand` membership 或 `DownloadSession.effectivePriority` 推断：
    `PipelineReaderSession` MUST NOT 在观察每个 7/3 physical download 时 eager attach ingress；
    存在 DecodeDemand / UploadDemand 时 MAY 建立 source projection，
    UploadRegistry 已批准的 retained static output MAY继续持有其 source/decode generation；
    三者均不存在时 MUST依次退休 idle upload/decode/native cursor、detach ingress并移除 SourcePool entry。
    `DownloadIngressProjectionRegistry` 只拥有有界 replay operation queue（默认最多2个）与实时 priority 排序，
    MUST NOT再实现 `>=1000 / 780..999 / <780` role gate或独立 memory-pressure eligibility。
    其 scheduler-owned `TaskControl` MUST贯穿 background Ingress/source execution；native source-write worker MAY并行执行已接纳的 reserve/copy/direct-file range，但 pending queue MUST消费同一动态 priority/cancellation，MUST NOT退化为独立FIFO scheduler，且取消后的in-flight native operation MUST真实退出后才释放worker capacity。
    `DecodeLane` 的 scheduler-owned `CancelToken` MUST继续贯穿 `DecodeSession -> ScheduledFrameCursor -> NativeCursor -> native decode pool`。pending native decode 在取得worker前 MUST响应同一 cancellation；numeric priority MUST在每次pending selection时直接读取同一TaskControl实时值，bridge MUST NOT复制priority字段或维护request-local priority subscription。current/nonCurrent execution class仍独立于numeric rank，current MUST优先于non-current，class内 MUST按priority降序、submission sequence升序。role promotion MUST先迁移DecodeLane priority再迁移同一native request class，MUST NOT以native-side addFirst/FIFO形成第二scheduler。已取得worker的native decode取消后 MUST等真实response/unwind才释放capacity；其cursor/source generation也 MUST等对应DecodeLane/UploadLane task真实退出后退休。详见 ADR 0339。
    native decode worker 与 source-write worker MUST具有显式独立 lifecycle，由composition并列prewarm/shutdown；worker exit MUST由各自pool的单一长期listener拥有，该listener直接结算至多一个current active request并退休dead worker。每请求 MUST只持有短命response port/subscription，不得向process-lifetime exit Future注册request-local continuation；pool MUST从live scheduling set移除exited worker并在仍存活时有界补位。replacement spawn失败但pool仍有至少一个live worker时 MUST保留pending并继续以degraded capacity执行，MUST NOT批量fail/clear无关queued requests；只有live worker为0且replacement也失败时才可终止无法执行的pending。busy/capacity MUST按真实active-run unwind结算，不能因worker先从列表移除就提前释放；decode仅剩一个live worker时non-current MUST让出最后slot给current。
    NativeCursor若在batch decode等待期间dispose，batch返回的所有尚未转交frame MUST立即release，不得把prefetched native frame写回已dispose cursor。详见 ADR 0338。
    SQLite artifact authority metadata MUST由 `SqliteIndex` owner connection 在一个短read transaction中返回object/replica/root一致snapshot，不得仅为该sub-millisecond查询建立常驻read worker；recency write MAY在既有 `StorageWriteScheduler` admission 后由专用worker执行。详见 ADR 0328。
    FrameBudgeter/memory pressure 只裁决native decoded/upload residency与media资源释放，
    MUST NOT再调整encoded/network flow credit；
    实际 persistent replay byte bandwidth 继续由共享 `ArtifactCacheReadScheduler` 拥有。

## Download storage / transfer detailed contract

The detailed normative contract for storage roots,direct/SAF access aliases, sparse version materialization,
cache/export retention, partial+network continuity,
failure feedback and Reader/manual shared resource scheduling is [`DOWNLOAD_STORAGE_SPEC.md`](DOWNLOAD_STORAGE_SPEC.md).
During the staged refactor, existing durable formats remain compatibility inputs,
but new behavior MUST preserve the contract there:
no global N-dependent page remapping, no speculative per-page expansion for unopened versions,
no UI-owned local/network stream concatenation, and no assumption that changing default export root invalidates readable replicas on older roots.
For schema-6 persistent ready artifacts, `artifact_object` MUST be consulted by `effectiveArtifactId` before the compatibility binding path;
it MAY replace `cache_entry.path/storageRootId` as the physical read locator only when artifact identity,
byte length, checksum and checksum namespace agree.A mismatch MUST retain the compatibility path.
Any `missing/lengthChanged` cleanup after such resolution MUST serialize/reference-check/delete the resolved physical locator,
whereas `accessDenied/ioFailure` MUST leave the logical binding and artifact identity intact.
SAF/Direct same-root aliasing MUST require the actual Android All-files grant plus bidirectional exclusive-canary proof;
provider/path/UUID similarity alone is insufficient.
For the system ExternalStorageProvider, `primary:` MAY derive a candidate from Android's primary external-storage root;
a non-primary volume id MAY derive one only from a unique current `StorageVolume.uuid` match with a non-null `directory`,
and ZIC MUST NOT guess `/storage/<uuid>`.
Unknown/ambiguous/unmounted volumes and generic providers remain SAF-only.
A successful proof MUST persist both locators under one App-private StorageRoot identity;
re-proving the same SAF tree after a mount-path change MUST keep that root identity and SHOULD prefer the most recently verified healthy Direct locator.
Ready-artifact access SHOULD prefer healthy Direct and MAY fall back to the proven SAF alias without copying bytes,
while `accessDenied` MUST degrade only the failed locator and MUST NOT invalidate the artifact.
The production App-level `DownloadResourceCoordinator` owns the current network and persistent-artifact local-read lanes;
Reader Pipeline and persistent download composition MUST consume the same injected authorities rather than creating competing production lanes.
`PipelineReaderSessionFactory` MUST require an explicit `pageDownloadLane`,
`PersistentDownloadComposition.open()` MUST require an explicit `transferNet`,
and `LiveCoordinator` MUST require an explicit `net`;
none of those composable production constructors may fall back to `NetLane(...)` internally.
When `LiveCoordinator` is attached to an external transfer consumer,
the supplied lane MUST be object-identical to the physical owner's lane.
A standalone `PersistentChapterDownloadService.open()` MAY own its own transfer runtime/lane only when it is itself the complete composition and is not paired with the shared Reader/download composition.
Plugin repository/install/update traffic and generic browse/details/request-plan traffic MUST remain explicit bounded control planes rather than acquiring the media `NetLane`:
repository sockets are owned/cancelled by `ExternalPluginController`,
while runtime operations use the plugin invocation gate.
Conversely, any Reader/download media body fetched through source-owned rhttp/OkHttp runtime compatibility MUST execute underneath an already-admitted composition NetLane physical task and MUST receive the same scheduler `TaskControl`;
plugin socket ownership MUST NOT become an independent media-concurrency authority.
A persistent-tier foreground cache hit MUST expose `ArtifactCacheStreamEntry.open()` directly and MUST NOT invoke `readAll`/whole-body collection before its first Reader chunk;
an existing memory-tier hit MAY use the direct byte body.
The remote Reader entry path MUST NOT call `readyPageIndices/readPage` to manufacture a second local full-byte loader for indexed artifacts;
it MUST register origin response capability and let `ArtifactCacheTransport` resolve persistent local authority first.
`local_media_ui` MUST reject a page composition that supplies both local-byte and origin-response loaders;
it MUST NOT implement local→network fallback or resume semantics.
Physical artifact read failures MUST use the typed cause namespace `accessDenied|missing|staleLocator|shortRead|lengthChanged|ioFailure` and preserve the absolute failed offset plus bytes emitted by that read request.
Platform bridges MUST preserve enough error identity to distinguish these causes;
they MUST NOT collapse every SAF failure into one generic error.
Raw byte access MAY omit replica identity only until the persistent repository enriches the failure with its authoritative replica record.
The persistent repository MUST attach the current replica identity before surfacing a read failure.
A recorded-vs-physical byte-length mismatch MUST surface as `lengthChanged` and invalidate only that affected replica/binding;
`accessDenied` or another access-path failure MUST NOT delete the artifact binding or physical bytes.
If one verified equivalent replica fails before a body is selected,
repository lookup MAY continue to another verified candidate;
if none succeeds, it MUST surface the retained typed failure rather than silently erase the cause.
A persistent cache/repository failure before body exposure MAY fall back to origin in the same open.
Once any local body bytes have been emitted, ArtifactCacheTransport MUST NOT concatenate origin bytes behind them;
it MUST surface the typed failure, quarantine that logical persistent path for the current transport lifetime,
and let a later Transfer attempt choose origin.
Structural replica failures `missing|staleLocator|shortRead|lengthChanged` MUST invalidate the affected durable binding;
`accessDenied|ioFailure` MUST preserve it.
DownloadJob MUST reset only the ephemeral resident projection after artifact-cache body failure and MUST NOT delete the external durable binding.
A controlled local restore cancelled because its scheduler/demand owner withdrew MUST leave the physical session idle/resumable with no terminal failure;
cancellation MUST NOT be published as restore corruption,
while non-cancellation restore errors remain explicit failures.
持久设置中的SAF目录wrapper固定为`saf://<content://...>`语义（实现字符串为`saf://`），runtime必须完整移除wrapper而得到无前导斜杠的`content://...`；
历史`/content://...`只允许由schema18作metadata-only修复，绝不能因此推导Direct proof。
