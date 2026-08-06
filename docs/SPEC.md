# zic Product and Engineering Specification

本文件是规范，不是实施报告。`MUST` 表示发布合同，`SHOULD` 表示默认要求，`MAY` 表示可选行为。实现和验证状态见 `IMPLEMENTATION_STATUS.md`。

## 1. 产品范围

zic MUST 支持 Android 上的本地/远程漫画、LTR/RTL/纵向阅读、静态图片、Animated WebP、partial/resume/offline artifact、漫画源浏览与受控插件扩展，以及本地 Debug Trace 导出。

项目不承诺 DRM 绕过、通用视频播放、社交功能或模型直接操作底层资源生命周期。

### 1.1 首页冷启动

- Home MUST 在本地库的 cover-bearing primary 数据可用后先呈现首页；native media
  prewarm、持久整本队列 restore、外部插件 activation 和 enrichment 不得成为首封面
  请求的硬门槛。
- 外部来源可以在首帧之后 ready；source projection 更新后，因来源暂不可用而失败的
  封面 loader MUST 能在 loader 改变时重试。
- 首页每张封面 MUST 独立完成请求和显示；一张封面变慢或 durable response 写入变慢，
  不得阻塞其它已经取得 encoded bytes 的封面。冷 miss MAY 先使用 memory source，持久化
  写入由统一 response cache 后台完成；已有 durable file hit MUST 保持文件直读。
- 首页封面 MUST 先通过 source-independent raw comic stable key 查询统一 response cache；
  命中时不得解析来源、创建 source transport 或等待插件 activation。raw miss 才可进入
  source loader，并必须写入当前 raw stable key；生产路径不得读取 dev.135 为 app 更新保留
  的 URL-derived/canonical 旧 key，也不得建立该兼容 alias。
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
- 来源详情若提供预览能力，详情页 MUST 能先显示 `ComicManifest` 中已经返回的预览项，
  后续页 MUST 通过 `ComicPreviewSource` 独立加载；预览图片必须复用统一 artwork loader，
  不得为详情页建立专用图片缓存或等待其它章节/评论请求。Venera 的 `@x/y` 裁剪标识
  MUST 保留在预览项和绘制身份中，同时传给 `onThumbnailLoad` 的 URL MUST 去除该标识；
  去除后的原图 URI MUST 是编码字节缓存和实际请求的身份，使同一原图的不同裁剪只产生一次
  请求/缓存项；宿主绘制时 MUST 只显示该标识指定的原图区域。图片失败时 MUST 使用按资源
  identity 稳定生成的柔和纯色占位，不得显示破损图片图标。
  预览栏默认 MUST 以单行横向缩略图呈现；用户点击“展开”后 MUST 改为左右分页的固定行布局，
  并自动继续加载来源分页，不得要求用户点击“加载更多”或使用纵向瀑布流。没有横向图的行
  SHOULD 放置三张纵向图；横向图 SHOULD 占两个纵向图槽位，因此可与一张纵向图同排。预览
  页的整体图片区域 MUST 不超过屏幕高度的 80%。缩略图和裁剪绘制 MUST 使用保持宽高比的布局，
  纵向与横向预览混排时允许留白，不得拉伸或强制裁切图片。
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
