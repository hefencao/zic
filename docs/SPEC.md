# zic Product and Engineering Specification

本文件是规范，不是实施报告。`MUST` 表示发布合同，`SHOULD` 表示默认要求，`MAY` 表示可选行为。实现和验证状态见 `IMPLEMENTATION_STATUS.md`。

## 1. 产品范围

zic MUST 支持 Android 上的本地/远程漫画、LTR/RTL/纵向阅读、静态图片、Animated WebP、partial/resume/offline artifact、漫画源浏览与受控插件扩展，以及本地 Debug Trace 导出。

项目不承诺 DRM 绕过、通用视频播放、社交功能或模型直接操作底层资源生命周期。

### 1.1 首页冷启动

- Home MUST 在本地库的 cover-bearing primary 数据可用后先呈现首页；native media
  prewarm、持久整本队列 restore、外部插件 activation 和 enrichment 不得成为首封面
  请求的硬门槛。
- 外部来源可以在首帧之后 ready；封面 presentation MUST 使用稳定 canonical artwork identity。因来源暂不可用、transport 或 decode 失败后 MUST 保持稳定占位，不得由定时器、App resume、first-frame watchdog、provider eviction 或 loader closure 变化自动重启请求；只有显式来源刷新、资源 revision 或稳定 identity变化才能重新加载。
- 首页每张封面 MUST 独立完成请求和显示；一张封面变慢或 durable response 写入变慢，
  不得阻塞其它已经取得 encoded bytes 的封面。冷 miss MAY 先使用 memory source，持久化
  写入由统一 response cache 后台完成；已有 durable file hit MUST 保持文件直读。
- 首页、书架和详情封面 Presentation State MUST 使用 canonical comic identity，不得因 raw Mihon alias、resume chapter、封面 URL 或 loader closure变化被销毁。Presentation MUST NOT 自己做定时 retry、first-frame watchdog、ImageCache eviction 或短时 Future join；资源重试/缓存所有权唯一属于 `ComicSourceResourceGateway/ResourceCacheManager`。
- 全局网络 User-Agent MUST 是 composition-owned fallback设置，默认采用稳定 Android Chrome UA并可由用户修改。来源 request plan显式 UA、browser-session UA或 source-owned client策略 MUST 优先；全局 fallback不得覆盖来源权威。
- App presentation MUST NOT 直接创建 `HttpClient`/`HttpURLConnection`或直接消费 source transport。生产 direct-network owner MUST 被限制在通用 transport、source-resolved host replay、source-owned runtime/client与插件安装 control-plane。
- host replay MUST 只用于可无状态平铺的单次 source request。遇到 redirect、`Set-Cookie`、未知 client wrapper、认证/session语义或成功 HTTP却非编码媒体响应时 MUST 切回 source-owned client；不得让独立 Dart HTTP client接管来源 Cookie/session状态。
- metadata/artwork MUST 经过 `ResourceCacheManager`；只有 Reader/章节 page body 与 artifact/download路径 MAY 通过明确命名的 page-body API绕过 response cache。插件仓库/APK/JS下载属于 control-plane，不得伪装成漫画 source response cache。 `CachedBrowsableComicSource` MUST NOT 暴露 artwork 加载 facade。`loadPageBytes` 与 streaming page loader MUST 共享同一 source-resolved response path；full-byte fallback MUST NOT 直接调用 raw source transport。章节下载的可变资源能力 MUST 作为单一 `ChapterResourceAccess` 原子绑定，不得使用多个 setter 形成半更新状态。
- 外部 artwork MUST 通过 source-confirmed canonical comic identity 查询统一 response cache；
  命中时不得解析来源、创建 source transport 或等待插件 activation。cache miss 才可进入
  source loader。raw Mihon/插件 locator只用于 runtime调用与章节身份，不得切分 durable artwork namespace。
- Home/阅读历史中已经持久化的 HTTP(S) artwork locator MUST 始终先进入统一 `ComicSourceResourceGateway` 的 source-independent durable-cache probe；active source/plugin 暂不可用时不得把网络 URL 交给本地文件 loader。durable miss 后才可要求来源 adapter。
- 已挂载 Home 的 chapter/SavedComic mutation MUST 通过 `HomeLibrarySession` write-through投影边界完成：durable store写入成功后同一次操作必须更新 session可见投影；不得先直接写 store再依赖详情页退出或 `_reloadLibrary()` 追平。Reader route最终 progress MUST 为 route-local状态，返回后只发布一次；不得用跨 route全局 latest-progress槽。
- Home library reload MUST NOT 用 mutation 之前捕获的旧 entries/SavedComic snapshot覆盖更新后的 write-through chapter/saved/progress投影。
- Comic artwork基础 cache schema revision MUST 只有一个 owner。External artwork由 `ComicSourceResourceGateway` 自动添加 `comicArtworkCacheSchemaRevision`；调用方 MAY 只提供 content-specific revision，MUST NOT 再传基础 schema revision形成并行 namespace。
- 初次 external runtime activation 在 session建立前发生 Binder `runtime-service-died/disconnected` 时，generation continuity MUST 由 Android runtime-service client拥有；最多跨一个 service generation。Dart/plugin activation层 MUST NOT 通过再次调用 activation实现同一恢复，业务/ABI/请求错误 MUST NOT 被重放。
- 来源确认过的同源 canonical comic identity SHOULD 持久化在 SavedComic 元数据中，供
  插件未激活时的书架只读归并使用；原始 comic/chapter request identity MUST 保持不变。
- 未访问的首页、书架、来源和杂项导航页 MUST 延迟构建；首次访问后页面状态 MAY 保留，
  但隐藏页面不得为首屏预先创建封面 loader 或重复发起 cover request。
- Home primary、enrichment 和可选 runtime 的状态仍 MUST 由各自 owner 管理；不得
  新增 App 私有正文/图片缓存或让 UI 直接调度网络。
- “更新漫画” MUST 只显示当前已在书架中的漫画，并按持久化的漫画元数据更新时间排序；阅读历史
  MUST 单独按 `ReadingProgress.updatedAt` 排序，普通阅读进度不得改变更新漫画集合或更新时间。

### 1.2 详情页与来源迁移

- 详情页顶部控制栏 MUST 不重复显示漫画标题；漫画标题只在详情内容区显示。
- 存在阅读进度时，详情页 MUST 提供可操作的“继续”药丸按钮；继续/阅读历史行 MUST 位于
  章节总数行上方，阅读历史 MUST 与按钮位于同一行并放在按钮之后，历史文字之前显示时钟图标。继续 MUST 通过既有
  `onOpenChapter` facade 打开保存的章节，不得等待无关的来源刷新。
- 来源漫画第一次打开后即使已持久化为 SavedComic，后续再次打开 MUST 复用当前已持有的 comic route identity lock，不得在同一调用链嵌套申请相同 `sourceId + comicId` 锁而静默吞掉导航。
- 详情页 SHOULD 提供同源版本入口；来源提供 `ComicVersionSource` 时，入口 MUST 使用来源
  自己的版本关系（Venera/E-Hentai 使用详情页 `#gnd`），不得改为标题 browse 或要求浏览器
  页面权限；没有该能力时 MAY 回退到来源 browse 结果。入口展示不同原生 `comicId`，不得把
  当前版本再次列为迁移目标。来源确认的新版关系 MUST 可持久化，使后续打开新版时也能显示旧版；
  旧版和新版都可作为同源迁移目标。
- 迁移面板 MUST 显示当前插件和当前来源，目标源 MAY 是当前来源或其他已启用来源。相同
  `sourceId` 下不同 `comicId` 是合法的同源版本迁移，适用于 URL/gallery locator 变化；
  目标漫画及章节身份 MUST 在任何持久写入前校验。
- 迁移 MUST 只复制整部漫画偏好、精确章节匹配得到的阅读位置/已读状态和有证据的 artifact
  复用关系。目标写入成功后，同源替换 MUST 清理旧版本的漫画/章节元数据；跨源迁移 MUST
  保留原来源。来源专属 URL 和离线字节不得被当作可直接复制的元数据。
- App-owned modal panel 的关闭操作 MUST 是左下角 X；确认、保存、删除等正向操作位于
  右侧，不得以“取消”文字按钮替代关闭 X。
- 漫画源页 MUST 使用来源自身声明的 browse section；Mihon Popular/Latest 与 Venera explore/category target 均属于来源内部分类。原生/Mihon/Venera 运行时类型 MUST NOT 作为内容分类行，只能以来源 chip 的视觉标识区分。固定大小 catalog page MUST 使用显式上一页/下一页，pager MUST 位于内容滚动尾部；切换来源、section 或外部搜索请求时 MUST 回到第一页。
- 切换漫画 source 时，Presentation MUST 在同一更新周期将 projection owner 切换为目标 source；MUST 优先显示目标精确请求缓存，其次目标最近缓存，没有目标缓存时显示目标 loading/error。旧 source 页面不得因目标请求失败继续可见。
- 强制刷新遇到 `sourceVerificationRequired` 且存在 WebView capability 时 MAY 自动进入一次目标 source验证。**任何一次**手动或自动验证浏览器 handoff都 MUST 消耗该 `sourceId + request URL` 的自动 fallback机会；若恢复重试仍失败，后续普通刷新 MUST NOT循环打开 WebView，只保留错误诊断和手动恢复。成功 browse后 MAY 清除该 guard。
- Cloudflare WebView恢复 MUST 优先打开 typed failure中的实际 request URL而非仅打开 source homepage；打开浏览器 MUST NOT预先删除已有 Cookie/snapshot。WebView `onPageFinished` MUST NOT直接等价于验证完成。浏览器内部 SHOULD 使用比网络 classifier更保守的 challenge探针，并且 MUST 要求同站点、`document.readyState=complete`、WebView progress=100以及连续稳定窗口内无可见 Turnstile/challenge form/running容器/`cf-chl-*`/challenge iframe或典型验证中间态，才可完成当前 Cookie/UA snapshot handoff；不得把“必须生成新的 `cf_clearance`”作为唯一成功条件。已有同站点/同 UA snapshot在新页面成功 capture前 MUST 保留，空 Cookie capture MUST NOT破坏已有非空 handoff。
- Cloudflare 验证浏览器 MUST 使用当前 Android WebView provider 的真实 User-Agent，MUST NOT用插件/OkHttp 的静态 UA覆盖验证 WebView。Cookie、localStorage 与真实 WebView UA MUST 属于同一 snapshot revision；Mihon runtime消费该 snapshot时必须让同站点 OkHttp请求采用同一 snapshot UA，并同步导入其 Cookie。
- WebView 验证返回后外部 runtime MAY 被重启。详情页与漫画源页的后续操作 MUST 按稳定 source ID重新解析当前 active adapter，MUST NOT继续调用重启前已关闭的 session。漫画源页 MUST 在 replacement source上重新加载 section/filter后再强制刷新，并禁止同一次恢复再次自动打开 WebView。
- `sourceVerificationRequired` MUST 只来自 typed host challenge detector：`cf-mitigated: challenge` 可直接确认；否则 MUST 同时满足 HTTP 403/503、Cloudflare Server header 与 `challenge-error-title`/`challenge-error-text` 交互 challenge DOM。`challenge-platform`/`cf-chl-*`脚本、`Just a moment`标题、Cloudflare header单独存在、普通 HTTP 403、timeout、解析失败和包含 Cloudflare字样的异常消息 MUST NOT被重分类。主网络与兼容 interceptor MUST使用同一 detector，不得使用隐藏 WebView。
- 漫画源搜索 MUST 以来源栏上方的浮动控件进入，展开后 SHOULD 提供可持久化、可删除和可清空的搜索历史。展开搜索面板 MUST 优先消费系统返回手势与垂直拖动/滚动手势，并在这些手势发生时恢复为浮动按钮。Mihon `getFilterList()` 支持的 CheckBox、TriState、Select 与 Group 子项 SHOULD 以不透明 ID 的过滤标签显示在搜索框上方；UI MUST NOT 持有或解释插件 Filter 对象。搜索结果 MUST 使用 catalog/resource-cache 权威：若有缓存，Presentation MUST 先显示缓存并后台刷新；只有稳定字段变化时才替换列表，不得建立页面私有结果缓存。漫画源页 MUST 支持边缘下拉达到阈值后的强制刷新；强制刷新 MUST 绕过 catalog cache，但 SHOULD 保留已有内容直到新结果到达。
- Mihon 插件的已安装列表和仓库列表 MUST 能按规范化语言分类；语言 SHOULD 优先使用插件声明，缺失时从插件 source metadata 推导。多个语言 MUST 归入多语言，无法可靠确定时归入未知语言，不得从显示名猜测。
- Mihon APK 识别 MUST 接受 manifest 中直接字符串或字符串资源形式的 extensionLib/entry class metadata；多个 entry class MUST 支持逗号、分号或换行分隔。候选识别 MAY 使用标准 extension feature/package prefix，但加载前仍 MUST 完成 package、signer、version、ABI 与 entry class 校验。
- Android 上 Mihon 共享扩展发现 MUST 至少合并系统包枚举与已知 package name精确探测；单个 APK 识别失败 MUST 保留 package、阶段和错误信息，不得被转换为空列表。系统包可见性受限时 MUST 向用户显示诊断。Mihon 私有 App目录不属于可访问的系统扩展边界，UI MUST 引导用户从 ZIC仓库安装，而不得声称已读取该目录。
- Production external-plugin runtime MUST use an explicit bounded active-session safety ceiling large enough for mixed installed sources; current composition sets 32. The generic test/embed default MUST NOT silently become a user-visible eight-plugin limit.
- plugin host MUST NOT 把 network bridge 的内部 browser-cookie session实现列为 Mihon common runtime ABI。Cookie snapshot reset MUST 通过稳定网络适配器边界调用。
- Mihon common runtime完整性预检中所有 `dev.zic.network.*` 动态类型 MUST 在 network bridge consumer R8规则中保留原始全限定类名和成员；typed `SourceVerificationRequiredException` 不得被混淆、裁剪或用错误消息字符串替代。
- 外部插件持久 manifest MUST 逐记录容错；一个坏记录不得清空其它已导入插件。写入 MUST 保留上一代 `.bak`；启动恢复 SHOULD 依次尝试主 manifest、`.bak`、残留 `.part` 和旧 `.invalid`，并允许旧 sandbox绝对 payload路径按 owned-root basename迁移。恢复记录仍 MUST 经过原有 payload hash、签名、ABI和 entry class检查。
- 来源详情若提供预览能力，详情页 MUST 能先显示 `ComicManifest` 中已经返回的预览项，
  后续页 MUST 通过 `ComicPreviewSource` 独立加载；预览图片必须复用统一 artwork loader，
  不得为详情页建立专用图片缓存或等待其它章节/评论请求。Venera 的 `@x/y` 裁剪标识
  MUST 保留在预览项和绘制身份中，同时传给 `onThumbnailLoad` 的 URL MUST 去除该标识；
  去除后的原图 URI MUST 是编码字节缓存和实际请求的身份，使同一原图的不同裁剪只产生一次
  请求/缓存项；宿主绘制时 MUST 只显示该标识指定的原图区域。图片失败时 MUST 使用按资源
  identity 稳定生成的柔和纯色占位，不得显示破损图片图标。
  预览栏折叠与展开 MUST 使用同一套排版结果：折叠态只显示第一行，高度由该行实际高度决定；展开态继续自动消费来源分页并以 `PageView` 左右分页呈现后续行。预览项 MUST 尽量保持来源原始顺序，并在可读尺寸下放置尽可能多的图片。完整行 MUST 直接使用全部媒体宽度反算等面积 tile，不得以外层 Card、重复水平 padding 或扩大 item gap 消耗剩余宽度；只有稀疏末行 MAY 放大到参考完整行面积的 2.4 倍。实际行含横图时最多 2 项，纯竖图行最多 3 项，并受用户设置的更小上限约束。阅读设置 MUST 提供每行最大数量 1–8，默认 4。图片区域 MUST 不超过屏幕高度的 90%，展开/收起按钮 MUST 居中且只显示箭头，不得显示“展开/收起”文字。不得拉伸、强制裁切或建立详情页专用图片缓存。
- 来源详情若提供评论能力，详情页 SHOULD 显示评论栏，并 MUST 支持分页评论次级页；
  评论存在回复数量和不透明 ID 时，次级页 MUST 能按原 source `subId`/回复 ID 加载回复。
  这些能力是可选的，来源未声明时不得发起插件请求。

## 2. Reader 行为

### 2.1 Current 与输出连续性

- current MUST 具有最高 download、decode 和 upload 优先级。
- near/far 工作不得阻塞 current；current 的 holder/播放状态也不得冻结目标页网络。
- 已有 output 在 replacement 前 MUST 保持可见；缺少动画 successor 时保持当前帧并等待 producer。
- loading MUST 绑定到具体媒体区域，不得用全局 overlay 隐藏已有页面。

### 2.2 翻页

- stable ownership midpoint 默认为 50%。
- 横向目标页覆盖率达到 0.15，纵向目标页真实进入视口时，MUST 建立 transition demand。
- transition 没有 decoded frame 时 MUST 可独立取得一帧，不得等待 current 下载完成、source sealed 或 current holder 达到基础水位。
- transition 首帧后，current 基础水位 MUST 先于 transition 深水位继续补充。
- midpoint 后新 stable page MUST 成为 current；旧页在仍可见时保留 last/transition output并暂停播放。
- 交接不得产生 targetless demand gap、黑屏或重新创建同一 identity。

### 2.3 连续模式与控制

- 内容 MUST 等比呈现，统一使用 `height / width`；不得裁切正文，或用负位移、重叠和多套比例公式掩盖接缝。
- Reader MUST 支持沉浸、跳页、暂停、倍速、方向和布局命令；命令只通过 Reader facade 提交。
- Reader 页码或阅读模式改变后 MUST 通过既有 progress facade 持久化 `ReadingProgress`；App
  lifecycle 进入 inactive/paused/detached 和 Reader route dispose 时 MUST 强制 flush 最近进度。
  Home projection MUST 在写入成功后立即更新，不能要求先退出详情页才反映阅读历史。
- Reader 正常返回前 MUST 等待最终 progress writer drain；详情页等待 Reader route返回后 MUST 立即重读本地 snapshot。异常进程终止只能依靠持续 checkpoint降低损失窗口，不得宣称绝对 crash-safe。
- UI 控件存在性 MUST 来自 capability，不得用静态/动画猜测下载或播放能力。

## 3. Pipeline 与角色合同

`ReaderObs` MUST 表达 stable page、fractional position、current/target coverage、viewport/physical target、阅读方向、interaction/zoom 和单调 revision。

默认资源策略：

- encoded download window：前 7 / 后 3；
- 深度 decode 角色：前 2 / 后 1；
- 动态 holder 最大水位为 current/next/next2/previous：7 / 5 / 3 / 2；
- upload primary：current、transition、last；
- lane normal concurrency：network 5、decode 3、upload 2；
- source bucket：local 2、remote 5。

Policy MUST 只输出 demand/keep，不得创建 transport、artifact、cursor 或 texture。静态一帧满足；推测静态预热 MUST 受预算限制。

## 4. 网络调度

- composition-owned `NetLane` MUST 是页面网络的唯一调度权威。
- current SHOULD 使用 priority 1000、一个高优先级 handoff slot和原位 priority migration；满足差值门槛时 MAY 抢占低优先级 active task。
- DownloadJob、Reader、UploadSession 和 holder 不得建立第二套网络资格门控。
- 目标页 receiving transport 不得因 current holder depth、播放 underflow 或页面控件状态被暂停。
- 不得通过缩小 7/3、关闭预下载或降低播放速度掩盖 identity、重复请求或 producer wake 缺陷。

## 5. 下载、partial 与 artifact

- GET/HEAD MUST 零 body且不得携带仅适用于实体 body 的 headers。
- 同一 DownloadId MUST 只有一个 active writer；partial MUST 是连续前缀并可恢复。
- seal/promotion MUST 原子更新 metadata；cache clear 不得删除 active artifact。
- 普通 transport 小块 SHOULD 首批约 16 KiB、后续按 64 KiB 合并后进入 session；传输实现的任意 chunk 边界不得放大为数万次 artifact/native append。
- local 和 remote WebP decode-prefix hint SHOULD 分别使用 1 MiB 和 256 KiB quantum；该 hint 不等同于 transport chunk。
- 读取失败 MUST 保留可归因错误，不得表现为永久 loading。

## 6. Animated WebP

- 两个 Dart decode isolate MUST 在 App 运行期常驻；libwebp 帧内 MUST 单线程。
- 首次 decode SHOULD 优先单帧；current 后续 MAY 每次批量返回最多两帧。
- holder MUST 是 decoded successor 的权威所有者；可见 output 不得计入 successor depth。
- transition depth 为 0 时 MUST 在 current 深水位前获得独立一帧；之后恢复 staged current/neighbor refill。
- 不得存在 startup-buffer、current-only decode gate 或以 playback buffering 控制其他页面 eligibility 的路径。
- metadata 未完成且 source 增长时 demux MUST 可刷新；未封缄 need-more-data MUST 等待 source revision，而不是定时销毁 cursor。
- native target canvas MUST 生成预乘 RGBA；Android/Flutter fallback 不得再次预乘。
- finite animation 到 EOF MUST 保留最后一帧；静态零时长帧不得启动 playback timer。

## 7. Upload 与 Android texture

- replacement 前旧 frame MUST 保持有效；release MUST 等待最后一个 frame owner。
- Android MUST 使用一个串行 blit lane；`scheduleFrame()` 和 MethodChannel result 必须在 platform thread有序完成。
- platform queue、schedule queue/call、blit 和 channel dispatch MUST 分别计时。
- 已承载 output 的 texture/SurfaceProducer MUST 随 output 释放，不得跨 Reader 会话复用。
- 只有从未呈现过的 prewarm lease MAY 短期复用；App 非 resumed 时 SHOULD 清理 idle prewarm。

## 8. Reader 资源会话生命周期

- Reader Host MUST 通过 factory acquire/release 资源会话，不能在 Widget dispose 中直接销毁所有章节资源。
- 实现 MAY 有界保留一个 idle 章节会话最多两分钟，以复用 Download/Source/Decode 状态。
- retention key MUST 使用稳定章节/source/loader revision，不得依赖临时 loader 对象 identity。
- retain 时 MUST 释放 Reader binding、page projection、playback wake、present claim和 used texture。
- TTL、key 变化、容量淘汰或 composition shutdown 时 MUST 完整逆序 dispose。
- retention 不得成为 Reader 私有正文缓存或 used texture cache。

## 9. Identity 与缓存

- 同一 request plan、DownloadSession、artifact 和 decode task MUST 按稳定 identity 合并；旧 epoch/revision 结果不得提交。
- 封面、详情、搜索和章节元数据 MUST 由统一 response cache 拥有，key 包含 namespace、稳定 identity 和必要 revision。
- Reader 页面 artifact MUST 由 `ArtifactCacheManager`/persistent backend 所有，不得进入 catalog response-cache 平面。
- 页面热字节 MUST 有界；默认可为 10 项/256 MiB。App/Reader 不得创建第二套图片 byte LRU。
- artifact alias MUST 有 checksum、来源 page key、内容 hash 或用户确认关系等明确证据；标题、URL token 或相同页码不足以证明等价。
- cache hit 不得共享 playback timer、cursor 或 decode identity。

## 10. 插件与来源

- 插件 MUST 在隔离、信任和权限门禁内执行，只返回 catalog 数据、request plan 或显式有界 transform 结果。
- 普通图片正文 SHOULD 由宿主 transport 流式下载。
- 插件不得访问导航、Reader、demand、artifact、App state 或底层缓存。
- Cookie、token、脚本 payload 和 Base64 正文不得原样写入 Trace。

## 11. Telemetry

Trace MUST 记录 demand/session/writer/source/decode/upload/present/retry/lifecycle 的可归因摘要。前若干不同帧 SHOULD 保留逐帧 timing，至少区分 lane queue、source wait、cursor/worker/native decode、upload backpressure、output prepare、platform/schedule queue、blit/replace和 channel dispatch。

identity 超限时使用稳定 hash 与原长度；高频事件 MAY 合并，但错误和生命周期边缘 MUST 保留。Trace 不得成为业务状态权威来源，overlapping total 不得与子阶段重复参与 dominant 归因。

## 12. 测试与发布

- owner test MUST 位于实现所属 package；App 测试不得导入低层 `src/` 或重复低层算法。
- 异步测试 MUST 使用可控 Future、状态对象或稳定 key，不得固定 pump 猜测完成。
- quarantine MUST 有稳定 ID、原因、仍运行的 owner 覆盖和解除条件。

发布候选 MUST 尽可能完成 analyzer、受影响 package/App tests、native tests、Android debug/release、Mihon/Venera/Android 合同、干净 ZIP 独立复验，并排除 `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、`target`、`__pycache__`、`.pyc`、`.class`、`.rej` 和 `.orig`。未执行项 MUST 在 Status/audit 标为 Unverified。

## Artwork 与插件会话稳定性要求

1. 失败封面不得因父组件 rebuild、App resume、timer/watchdog或第二个 ImageStream自动重新发起请求；Presentation MUST 保持稳定占位，只有显式来源刷新、资源 revision或稳定 identity变化才允许重新加载。
2. 实际预览行含横图时 MUST 最多 2 项，纯竖图行 MUST 最多 3 项；为满足该规则 MAY 在相邻三个候选内做一次最小局部重排，并受用户设置的更小上限约束；不得用额外间隔消耗剩余宽度。
3. 详情与漫画源下拉刷新 MUST 共用同一个组件拥有 edge trigger、位移、刷新进度和成功/失败反馈；结果图标 MUST 与刷新指示器使用同一落点。

4. encoded artwork source 已就绪后，普通 artwork MUST 只创建一个 ImageProvider/解码监听；需要裁剪或尺寸测量的 Presentation MAY 显式监听一个 ImageStream并直接绘制 decoded image，但 MUST NOT 同时构建第二个 `Image`监听同一 provider。
5. 远程详情 MUST 先显示已有 catalog cache，并等待当前 active source adapter 完成后台刷新；预览、评论及章节操作 MUST 在调用时解析当前 adapter，不得持有插件重启前的关闭 session。
6. Mihon chapter catalog MUST 只投影插件/source API实际返回的完整 `SChapter` 列表。TachiyomiX 1.6/current Mihon MUST 先调用 `getMangaUpdate(manga, existingChapters, ..., fetchChapters=true)`；只有 combined能力明确不存在时 MAY回退 legacy `fetchMangaDetails/fetchChapterList`。正文 MUST先调用 `getPageList(SChapter)`，只有能力不存在时 MAY回退 `fetchPageList`。成功空列表是合法结果；真实调用错误保持失败。MUST NOT 从 manga URL生成兼容单章，也不得按标题、`SChapter.url`、number或sequence推断、增加、删除或合并章节。
7. Reader progress 的有序性与 durable I/O MUST 解耦：SQLite实现 MUST 在非 UI isolate执行同步 sqlite3/章节校验；Reader页面变化只入队 latest checkpoint，不得逐页发布 Home/library projection。Reader route MUST NOT 等待 durable barrier；返回后 Home/详情只发布最终内存 progress投影，storage isolate按自身 batch/生命周期策略完成持久化。
8. 外部 artwork MUST 统一通过 `ComicSourceResourceGateway`；raw plugin comic locator 与 durable artwork identity MUST 分离。Mihon 等可变 raw locator必须使用 source canonical comic identity构造封面/预览 cache namespace；`mihon:resource:` 等插件 URI不得传给本地文件 loader。
9. 同一 browser snapshot revision MUST NOT 在每个 HTTP 请求前重复覆盖 runtime Cookie；新 revision可再次导入。Mihon首个重试 MUST能从 snapshot同步获得 cookie，不得依赖 Android `CookieManager.setCookie()` 的异步持久化时序。
10. retryable runtime lifecycle envelope MAY 自动重新激活并重试一次；业务错误和 `source-verification-required` MUST NOT 被当作 runtime崩溃吞掉。
11. Mihon/外部插件同 pluginId 的 runtime restart或更新 MUST 使用事务式 replacement：候选 session先完成 activation、source identity/ABI等验证，成功后才能替换当前 source owner并关闭旧 session；候选失败 MUST 保留旧 session。不得先 deactivate再尝试 activate。
12. Mihon `imageRequest(page)`（或等价 source request）的 URL、method、headers与必要 request body MUST 原样进入 `ComicResourceRequest`；GET/HEAD body MUST 为 null。宿主直连 MAY补 source OkHttp CookieJar的当前 Cookie与 browser-session UA，但不得把普通图片完整 body路由回插件 JSON/Base64 RPC。
