# zic Architecture

本文件描述当前生产代码的稳定所有权、依赖方向、数据流和生命周期。它不记录版本历史、单轮 Trace 数字、测试通过情况或待办事项。

## 1. 架构目标

- current 具有最高资源优先级，但目标页首帧不得依赖 current 的下载完成或 holder 深度。
- 同一稳定 identity 只有一个权威 request、session、artifact、cursor 和活动 writer。
- Reader 只提交 observation/用户命令并消费只读输出，不直接操作 transport、session、artifact、lane、frame 或 texture。
- 下载、解码、上传使用独立 scheduler；一个层的运行时状态不能成为另一层页面的资格门控。
- 平台能力由 composition root 原子注入；核心包不反向依赖 Widget、Android plugin 或具体 FFI 实现。
- 创建者关闭 owned 对象；外部注入能力不得被消费方误关闭。

## 2. 分层与依赖

```text
Presentation
  apps/app, local_media_ui, reader_runtime, reader
        |
Composition / platform adapters
  pipeline_native, downloads_bridge, storage_bridge,
  local_media_bridge, network_bridge, plugin_host_bridge,
  runtime_bridge, texture_bridge
        |
Policy / resource runtime
  pipeline, pipeline_runtime, downloads, sessions
        |
Domain / contracts
  domain, catalog, resource_cache, transport, storage,
  media, telemetry
        |
Native implementation
  bridge, native/media_core
```

依赖只能向下或指向稳定抽象。底层包不得读取 Widget、路由、App controller 或页面控件状态。

## 3. 包所有权

### `domain`

领域 identity、值对象和不可变实体。`TaskControl` 是 scheduler-owned work 跨层只读控制合同，只暴露 cancellation 与 priority；消费层不得借此拥有调度策略。不得依赖 UI、插件、网络、缓存、数据库或平台桥。

### `catalog`

漫画源、漫画/章节/page manifest、来源能力和 catalog cache identity。`CachedBrowsableComicSource` 只缓存 browse/details/chapter metadata，不拥有 artwork 加载；Reader 页面正文仍透传到统一 Pipeline。

### `resource_cache`

封面、详情、搜索、章节元数据等可重新获取响应的唯一缓存平面，拥有容量、TTL、分类预算、in-flight 合并、持久 byte store 和失效策略。

### `transport`

可取消、可分块的 encoded-byte transport、range、validator 和 response 合同。Reader page 使用可选 `ControlledTransport` 将 scheduler `TaskControl` 贯穿 source-plan/open/response body；transport可中止自身请求但不拥有 priority policy，也不得在请求真实退出前伪释放 lane容量。prefix probe后outer stream取消仍必须abort底层response。它不拥有 artifact、Reader demand 或播放状态。

### `storage`

partial artifact、连续前缀、校验、seal、原子 promotion、索引和临时 workspace。partial append只写入并推进长度，不在UI isolate逐chunk计算CRC；seal/restore在isolate rehash后提交权威checksum。它不决定页面角色或网络优先级。

### `downloads`

composition-owned `ArtifactCacheManager`、artifact transport/read scheduler、已验证 alias/rekey、章节/整本持久下载与来源 transport 组合。页面 session 状态本身由 `sessions` 拥有。

### `media`

encoded source、cursor、frame、output、renderer 和只读 timing capability。它不选择页面角色或 scheduler 策略。

### `sessions`

`DownloadSession`、`DecodeSession`、`UploadSession`、registry、claim/lease、frame holder、playback timer、Net/Decode/Upload lane 和 `LiveCoordinator`。它是可变媒体状态的权威所有者。

### `pipeline`

把 `ReaderObs` 纯计算为角色窗口和 `DemandPlan`。它定义优先级、水位和 keep 集合，但不创建 transport、artifact、cursor 或 texture。

### `pipeline_runtime`

Reader 章节资源会话的唯一组合所有者。它把 demand reconcile 到 download/decode/upload session，发布 `PipelinePageStream`，管理 frame budget、共享 page download lane、artifact handoff 和短期资源会话 retention。

### `pipeline_native`

把 native source factory、cursor、frame uploader、output projector 和 prewarmer 作为原子 capability 注入 `pipeline_runtime`。核心 Pipeline 不直接创建具体 FFI 或 Android texture 实现。

### `reader_runtime` / `reader`

`reader` 提供 observation、导航和通用 Flutter Reader；`reader_runtime` 负责产品交互、尺寸投影和 `ReaderObs` 适配。二者都不拥有资源 session、缓存或 native handle。

### Home 冷启动组合

`apps/app` 的 Home 关键路径只等待能产生封面的本地库 primary 数据和内置来源。
进程级 native media prewarm 在 Bootstrap/App 呈现后后台运行；持久整本下载队列以
`ready` Future 恢复；已安装外部插件由 `ExternalPluginController.openDeferred` 先完成
manifest 准备，再在后台完成设备扩展发现和 runtime activation。Home 在插件 ready 后
增量替换 source projection，不重新拥有或复制资源缓存。

`HomeLibrarySession` 先发布 entries/SavedComic primary，交给 Flutter 完成一个可注入的
首帧边界，再读取 enrichment 和写入缺失默认值。已挂载 Home 的 chapter/SavedComic mutation
必须通过该 session write-through：durable store 仍负责持久化，session 在同一次成功写入后立即替换
可见投影，不能依赖后续详情页或全量 reload 追平第二状态。外部 artwork 的恢复/cache权威只有
`ComicSourceResourceGateway/ResourceCacheManager`：presentation取得一个不可变
`EncodedResourceSource` 后只建立一个 ImageProvider。response cache拥有的持久文件是可撤销实现细节，
不得把其路径借给 Flutter；跨 cache 边界必须物化为 presentation 自持有的 encoded bytes。只有导入的
稳定本地文件可使用 `FileEncodedResourceSource/FileImage`。Future/ImageStream失败保持稳定占位，
普通 rebuild、App resume、timer/watchdog或 ImageCache eviction都不得自动建立第二套请求。
首页 artwork 的冷 miss 在 encoded bytes 到达后可先返回 memory source，durable response
写入由 `ResourceCacheManager` 后台排队；同一批封面按卡片独立完成，不等待全部封面或
全部持久化写入。gateway以 source-confirmed canonical comic identity探测 durable artwork
namespace；命中时不解析 source、不创建 plugin transport，miss才进入真实 source loader。
raw Mihon locator继续只用于插件 request/chapter identity，不参与 durable artwork分区。未访问的
首页、书架、来源和杂项页由 lazy indexed page 保持未构建，避免隐藏导航页提前创建第二套
封面 loader；访问过的页面状态仍由该页面节点保留。

Home 的“更新漫画”投影只取已在书架且具有 `SavedComicRecord.sourceUpdateAt` 的漫画，并按该
source-confirmed更新时间排序。`sourceUpdateAt`只在已有章节目录基线变化或首次发现新的同源 successor/version时推进；
普通 metadata刷新、阅读进度与仅浏览记录都不产生更新。漫画源卡片从同一 Home/library 投影读取书架与更新事实：
左上书架标志+变暗只表示当前 raw/canonical comic已入书架；右上感叹号只提示该书架 comic有 source-confirmed update。阅读历史
单独按 `ReadingProgress.updatedAt` 投影。

### 详情页与来源迁移组合

`ComicDetails` 只把详情展示、阅读进度和用户命令投影到 Flutter；详情 AppBar 不重复显示
漫画标题，标题只在详情内容区出现。保存过阅读进度时，继续阅读命令直接调用既有
`onOpenChapter` facade，按钮和阅读历史是两个独立的 UI 投影，并位于章节总数行上方；详情页不创建第二个阅读器或
正文缓存。来源浏览、manifest/chapter 身份校验、状态迁移和 artifact 复用由
`_DemoHomeSourceMigration` 组合 owner 完成。

同源版本关系只来自来源 `ComicVersionSource` 或已持久化的 `ComicVersionRelationStore`；Venera/E-Hentai按来源关系生成版本，
不得用标题 `browse` 推断同源。通用“迁移漫画源”入口允许选择当前来源或其他已启用来源：跨源标题搜索只用于候选发现，
同源面板只展示来源确认的 successor/predecessor，并同时提供“查看”与“迁移”。查看直接打开目标 raw identity，不改变状态；
迁移无论同源/跨源都进入唯一 `ComicSourceMigrationPlan + showSourceMigrationComparison`，只有 exact chapter match复制偏好、阅读位置和已读状态。查看路由只使用 `source-version-view` **temporary route identity**；同源替换完成后新 raw locator成为实体并清理旧 alias preference/metadata，离线 artifact只按验证证据复用。

漫画源页使用来源自身声明的 browse section：Mihon 映射 Popular/Latest，标准展示顺序为“最新 → 热门”，Venera 枚举 explore loader 与 category target；首次进入来源时默认 section必须由**当前展示顺序的第一项**决定，不能另写 `popular` 默认值，也不能让最近一次 catalog cache projection反向选择 UI。未来用户自定义排序若改变 Presentation顺序，同一排序 owner自然同时决定默认焦点。原生/Mihon/Venera 仅通过来源 chip 的背景色区分，不显示 JS/插件图标，也不占内容分类行。`FilterableBrowsableComicSource` 只投影来源真实 `FilterList`：空 schema即没有筛选入口，不另设容易漂移的 capability布尔值。Mihon bridge必须按官方 `Filter.Header/Separator/Select/Text/CheckBox/TriState/Group/Sort` 基类继承关系识别插件自定义子类，并保留 Group层次与 Text/Sort状态；用户修改以类型化 filter-state override进入 search request。筛选是否激活是独立 Presentation/request mode：空 override表示使用插件默认 `FilterList` 状态而非“未筛选”，激活后分类栏焦点属于“筛选”且请求不继承 latest/popular section；Catalog cache identity与runtime payload必须显式区分 filter mode和普通 section mode；external browse的 typed factory、wire validator与 adapter payload必须共享同一字段契约，schema v1新增 `useFilters` 可缺省兼容但未知字段仍拒绝。Filter不得伪装为 `SourceBrowseSection`，浮动搜索只拥有 query与搜索历史。browse projection revision 只属于 metadata，不能作为整页 artwork reload token；source card 的 Sliver child owner 使用 canonical comic identity，raw locator变化不得重置封面 State。固定大小的 catalog page 仍使用显式上一页/下一页，pager 位于内容滚动尾部。列表由 catalog response cache先行投影，但 cache只能服务**当前精确 UI 请求**，不得用“最近 projection”改写 section/query/filter默认状态；source切换时 projection owner先原子切换到目标 source，旧 source内容没有展示资格。后台 refresh只有在稳定字段发生变化时才更新 Presentation；边缘下拉达到刷新阈值后强制绕过缓存请求来源，但保留当前内容直到新数据到达。Mihon 插件的已安装与仓库列表仍按规范化语言分类。

详情页与漫画源页的统一刷新由 `AppPullToRefresh` 拥有 edge trigger、72 px位移、进行中状态与成功/失败结果图标；页面不得叠加第二套刷新状态。

详情扩展数据由 source adapter 负责：`ComicManifest` 可携带首批预览缩略图和评论，
`ComicPreviewSource`/`ComicCommentSource` 只在来源声明能力时提供继续分页。App 只消费
规范化 URI、评论字段和不透明的 `sourceSubId`/回复 ID；图片仍走统一 artwork cache，
评论完整列表和回复通过详情次级页加载，不把评论请求或插件 transport 变成章节目录的
全局门控。Venera 直接复用 `comic.loadThumbnails` 与 `comic.loadComments`，因此已有
`ComicDetails` 能力的来源可渐进显示预览、评论和回复。预览 URI 保留 Venera 的
`@x/y` 裁剪标识用于预览项/widget/painter 的单项身份，但 `onThumbnailLoad` 请求回调接收
去掉裁剪标识的原图地址；该 base URI 也是编码字节缓存身份，App 解码后只绘制对应裁剪区域。
预览栏折叠与展开共用同一套顺序布局。实际行含横图时最多 2 张，纯竖图行最多 3 张；只允许在相邻三个候选内做最小局部重排。完整行直接用全部媒体宽度反算等面积 tile，不再把剩余宽度变成外边距或巨大项间距；标题保留普通内容边距，但图片区不叠加 Card 或水平 border/padding。只有稀疏末行允许相对完整行放大，面积上限为参考完整行的 2.4 倍。阅读设置提供每行最大数量 1–8，默认 4。折叠态只显示同一布局第一行，高度取第一行实际高度；展开态继续消费来源分页，并由 `PageView` 左右分页呈现后续行。展开图片区域按屏幕高度 90% 封顶，开关位于中间且只显示上下箭头。行规划优先使用 `ComicPreviewAsset.width/height`，缺失时以解码后的可见裁剪尺寸回填；缩略图使用 `BoxFit.contain`，不拉伸或强制裁切。预览失败只显示按资源 identity 生成的柔和单色占位，不显示破损图片图标。

App-owned modal panel 的操作行由 `AppDialogActions` 统一投影：关闭固定为左下角 X，确认、
保存或删除位于右侧，不再使用“取消”文字按钮。

### 插件与平台桥

- `plugin_host`：信任、权限、请求计划、身份适配和插件生命周期。
- `plugin_host_bridge`：Android 隔离进程与 Mihon/Venera runtime 适配。Mihon 设备发现只覆盖作为系统共享 APK安装的扩展，合并 `getInstalledPackages`、`getInstalledApplications` 与已知仓库 package name的精确 `getPackageInfo`；每个候选的 manifest、metadata、签名、ABI与 entry失败必须返回诊断，不得静默丢弃。Mihon App私有 `filesDir` 中的扩展不能跨 App读取，必须从 ZIC 仓库独立安装。APK 候选按扩展 feature 或标准 package prefix识别；entry/ABI meta-data随后从 manifest原值或字符串资源解析，多个 entry class可用逗号、分号或换行分隔。隔离 runtime 的公共网络 ABI只要求 `AndroidCookieJar` 等稳定适配器，`AndroidBrowserCookieSession` 属于 network bridge内部实现，不得被 plugin host直接 import或列入 common runtime必需类。动态 ABI按原始类名加载 `dev.zic.network.*` common 类型；所有列入完整性预检的网络类型必须由 `network_bridge` consumer R8规则显式保留类名和成员，不能依赖普通源码引用阻止 Release混淆。
- `network_bridge`：浏览器、Cookie/localStorage 快照、challenge 恢复和共享网络能力。
- `bridge`：Dart FFI、native source/cursor/frame ABI 和两个进程常驻 decode isolate。
- `texture_bridge`：Android texture lease、SurfaceProducer、单 lane RGBA blit、schedule 和 release。
- `apps/app`：composition、导航和产品页面；不得定义资源算法。

## 4. Reader 数据流

```text
Reader interaction / viewport / presentation size
  -> ReaderObs
  -> RoleResolver + HeuristicPolicy
  -> DemandPlan diff
  -> PipelineReaderSession / LiveCoordinator
  -> DownloadSession -> DecodeSession -> UploadSession
  -> PipelinePageStream
  -> reader_runtime / Reader presentation
```

Reader 可以提交 stable page、fractional position、目标页覆盖率、阅读方向、viewport/physical target、interaction/zoom，以及 pause/resume/speed/jump 等命令。

Reader 只能消费不可变页面状态、进度、错误和 `PipelinePageSurface`。它不得接触 mutable session、transport、artifact store、scheduler、cursor/frame handle 或 texture registry。
`reader_runtime` 在页码/阅读模式改变时通过既有 progress facade 提交最新 checkpoint。SQLite 实现
使用独立 progress isolate/WAL connection；Reader 热路径只将 checkpoint 有序入队，不执行同步
sqlite3、章节 JSON 解码或 `HomeLibrarySession` 发布。每个 Reader route 只在 composition 内持有自己的
latest progress；route 返回后只把该最终 progress 发布到 `HomeLibrarySession` 一次，不等待 durable
barrier，也不 reload library/history。磁盘完成不得成为翻页或退出动画的前置条件。
`HomeLibrarySession` 同时记录 library projection revision；reload 在开始阶段捕获的 entries/SavedComic snapshot如果在 enrichment期间已被 write-through mutation超越，结束时不得覆盖更新后的 mounted projection，download snapshot也必须基于最终可见 entries。
inactive/paused/detached 继续主动入队最终 checkpoint，进程被系统直接终止只提供 best effort。

## 5. 页面角色、窗口与优先级

`RoleResolver` 使用以下角色：

- `current`：stable page；
- `last`：刚离开 current 的 keep-only output；
- `transition`：拖动目标页；横向覆盖率达到 0.15，纵向只要真实进入视口即建立；
- `next`、`next2`、`previous`：深度预解码角色；
- `near`、`far`：只保留 encoded download 的邻页；
- `detached`：窗口外。

稳定 encoded window 为前 7、后 3。深度 decode 角色窗口为前 2、后 1；更远页面仍可下载，但不获得动画深水位。

网络优先只由 composition-owned `NetLane` 负责：

- 全局正常并发 5；local bucket 2，remote source bucket 5；
- current priority 1000，保留 1 个高优先级 handoff slot；
- priority 提升原位迁移，差值达到 40 时可抢占低优先级 active task；只有一个 max+1 handoff，取消中的 task在真实结束前继续占用 permit。普通页面离开 encoded 7/3窗口时，queued undemanded任务可取消，但已 receiving 的传输保留并降为低优先级；只有新的 current真实形成pressure时才抢占低rank receiving。Venera单上下文runtime同样执行pressure-only current抢占，不因logical detach直接cancel；
- DownloadJob 不读取 holder depth、播放状态或页面控件，不存在第二套网络资格门控。

## 6. Decode 水位与 Transition 首帧

动态页面的 role 最大 holder 深度为：

```text
current / logical next / next2 / previous = 7 / 5 / 3 / 2
```

`transition` 是拖动期间的 logical next，但它在任何 current 深化之前拥有独立首帧：

```text
transition depth 0 -> t>0，目标 1 帧
```

取得首帧后，staged refill 顺序为：

```text
c>2, n>1, m>1, p>1, c>4, n>2, c>6, n>3, m>2, n>4
```

其中阈值是严格水位，实际 batch 可自然越过。高优先级且 `targetWatermark=1` 的 one-frame demand 可与 staged decision 比较优先级，但不得恢复 startup-buffer 或 current-only gate。

静态页由 runtime 分类；一帧即满足。推测静态邻页可在 96 MiB 选择预算内获得 decode/upload，实际 decoded/output 回收仍由 `FrameBudgeter` 权威执行，默认 output budget 为 128 MiB。

## 7. 下载、partial 与 source ingress

普通 response 进入 `DownloadJob` 后先合并 transport 的任意小块：首批约 16 KiB，后续按 64 KiB source-progress quantum 提交到 `DownloadSession`。这与 WebP decode-prefix hint 是两个独立概念：

- local/content/file/asset prefix quantum：1 MiB；
- remote prefix quantum：256 KiB。

`DownloadSession` 保证连续前缀、单 writer、validator/range、seal 和 promotion。已 receiving 且仍有 demand 的传输不会因 observation revision 机械重建；current priority 变化在同一 lane/session 上迁移。

完整 local immutable 或 durable cache response可标记 resident，并经权威 session/source ingress；错误、取消、range response 或长度不一致不得写入完整热字节。

Home/书架封面上的下载完成标记只表示**显式下载命令完成后的临时反馈**，不表示 durable cache residency。单章节命令和整本队列命令必须区分；整本标记只能由 `WholeComicQueuePhase.complete` 产生，任意一个 `ChapterDownloadSnapshot.isComplete` 无权推导整本完成。该反馈属于 Home Presentation、以 canonical comic identity关联，并在用户进入该漫画详情时消费；真实离线状态仍由 downloads/artifact owner维护。

## 8. Animated WebP 生产与播放

```text
transport / artifact stream
  -> DownloadSession ingress
  -> native growing source
  -> demux metadata / NativeCursor
  -> process-lifetime Dart decode isolate
  -> libwebp single-thread frame decode
  -> premultiplied target-canvas RGBA
  -> FrameHolder
  -> UploadSession
  -> Android texture 或 Flutter fallback
```

稳定约束：

- 两个 decode isolate 在进程期常驻；libwebp 帧内单线程；
- 首次 native 请求优先单帧，current 后续请求最多批量返回两帧；
- holder 是 decoded frame 的权威缓冲；可见 output 不计作 successor；
- 缺少 successor 时保持当前 output，等待 producer 通知，不进入 startup-buffer，也不阻塞其他页面 decode；
- playback 使用最近 deadline 的 one-shot wake；静态零时长帧不启动 timer；
- finite animation 到 EOF 保留最后一帧；
- metadata 未完成且 source 增长时允许刷新 demux；未封缄 `needMoreData` 等待 source revision，不用定时销毁 cursor；
- target canvas 使用 contain 和 `height / width`，不裁切、不使用负位移或页面重叠掩盖接缝。

## 9. Upload 与 Android texture

primary upload 角色为 current、transition 和 last；last 只冻结并保留已有 output，不继续 decode。推测静态邻页可在预算内预上传。

Android 路径使用默认 platform MethodChannel、一个串行 blit lane和普通 `mainHandler.post`：

1. retain native frame；
2. 单 lane 复制预乘 RGBA；
3. platform thread 调用 `SurfaceProducer.scheduleFrame()`；
4. 原子替换 output retained frame；
5. 返回 MethodChannel；
6. UploadSession 记录 presentation 并推进 deadline。

已承载页面 output 的 texture lease 在 output 结束时真实释放，不回到 Reader 间复用池。只有从未呈现过的预热 lease 可短期复用，App 非 resumed 时清理 idle prewarm。platform queue、schedule queue/call、blit 和 channel dispatch 必须分别计时。

## 10. Reader 资源会话 retention

Reader Host 从 `PipelineReaderSessionFactory.acquire` 获取资源会话并在退出时 `release`。退出 Reader 不等于立即驱逐整章资源：

- retention pool 最多保留 1 个 idle 章节会话；TTL 为 2 分钟；
- key 包含稳定章节/source revision、loader URI/revision 和 composition 能力指纹；临时 loader 对象 identity 不参与；
- 保留 DownloadRegistry、SourcePool、DecodeRegistry、artifact handoff、media runtime 和 workspace；
- 释放 Reader binding、page projection、playback wake、present claim 和 used texture；
- 不同 key、TTL 到期、容量淘汰或 composition shutdown 时才完整逆序 dispose。

这是一条资源 lease，不是 Reader UI 缓存，也不允许跨 Reader 复用 used SurfaceProducer。

来源页打开已经持久化为 `LibraryComic` 的同一漫画时，source route lock 是该导航的唯一 presentation lock；不得在持有同一 `sourceId + raw comicId` lock 时再次调用会重复申请该 lock 的入口。路由锁只存在于内存导航生命周期，不写入 library，也不参与持久 identity。

## 10.1 Reader progress 与阅读历史

Reader 页面变化产生的 `ReadingProgress` 由 `reader_runtime` 串行合并后写入 App 提供的 progress facade。同一 Reader 同时只有一个 active writer；较新的 pending progress覆盖尚未开始写入的旧值，禁止并行 Future 倒序完成后覆盖新页码。

正常导航返回不等待 SQLite pending/active writer 清空；Reader callback只 enqueue checkpoint，composition route-local `latestProgress` 在 pop 后立即替换 Home/详情内存投影一次，因此阅读历史不依赖再次进入详情或整库 reload。`inactive`、`paused`、`detached` 和每次稳定页面变化继续 best-effort checkpoint，以降低进程意外终止的损失窗口；操作系统强杀无法提供绝对完成保证，文档和 UI不得声称 crash-safe commit。

## 11. Identity、缓存与 artifact

不同 identity 层不可混用：catalog identity 定位实体；DownloadId 表示确定字节版本；DecodeId 还包含 epoch、target 和 renderer；presentation identity 只表示页面位置/输出。

缓存分为两个权威平面：

- `ResourceCacheCoordinator.responses`：封面、搜索、详情和章节元数据，使用稳定 namespace/identity/revision、weight、TTL 和 in-flight join；external artwork 使用 source-confirmed canonical comic identity + role，raw runtime locator 不参与 durable artwork 分区；
- `ArtifactCacheManager`：Reader 不可变页面 artifact，默认热字节 10 项/256 MiB、alias 上限 8192，并连接持久 backend。

封面 URL/token 不是稳定 comic identity；verified checksum、来源 page key、内容 hash 或用户确认迁移才可注册 artifact alias。App/Reader 不得创建私有图片字节 LRU，也不得让 cache hit 共享 cursor、timer 或 decode identity。

### 11.1 当前生产代码的 key/id 对照

以下是现有实现中容易被混称为“key”的几组身份。它们的用途不同，不能用标题、显示名或
图片 URL 互相替代。

| 名称 | 所有者/含义 | 当前组成和用途 |
| --- | --- | --- |
| `sourceId` | 来源身份 | 插件/来源的稳定 ID，不是来源显示名；参与 source namespace、漫画 namespace、`ContentId` 和资源请求绑定。 |
| raw `comicId` | 来源原生 runtime locator | `Comic`、`SavedComicRecord`、`LibraryComic` 与章节归属保留的原始漫画定位值。Mihon 可把可变 SManga 快照编码进该值，因此它只保证“如何再次调用插件”，不得假定为 durable artwork identity。 |
| `LibraryComic.identity` / Flutter comic key | 书架实体身份 | 当前为 `sourceId\u0000comicId`（UI key 再加各自前缀）；标题、作者和封面 URL 都不参与。两个同名漫画只有在这组身份也相同才会被视为同一个实体。 |
| `canonicalComicId` | 来源确认的稳定同源身份 | 由来源从 raw locator 投影的稳定等价值，用于冷书架归并和 durable comic/artwork namespace；不得替换插件请求、章节或 Reader `ContentId` 中的 raw `comicId`。Mihon 当前以规范化漫画 Web URL投影 canonical identity。 |
| `chapterId` | 来源原生章节身份 | `Chapter`/`ChapterManifest` 的章节身份；章节元数据响应 key 使用 `[sourceId, chapterId]`，并挂到已知漫画 namespace。 |
| `pageId` / `PageAsset.assetKey` | 章节内页面身份 | `PageAsset` 保留 `pageId` 和 `chapterId`，`assetKey` 为 `chapterId/pageId`；它不是封面/预览响应缓存 key。 |
| `ContentId` | Reader 内容实体身份 | `[sourceId, comicId, chapterId, pageId]`，用于确定一个漫画章节页面；`ContentId.key` 只服务 Reader/download identity。 |
| `DownloadId` | 确定字节版本 | `ContentId + sourceRevision + canonicalUri`，用于 Reader 下载/artifact；页面 URL 变化或来源版本变化会形成新的确定字节身份。 |
| `DecodeId` | 解码输出身份 | `DownloadId + physicalWidth + physicalHeight + pixelFormat + renderer`；不参与首页/详情的图片响应缓存。 |
| `ResourceCacheKey` | 响应缓存实体身份 | 四元组 `kind + identity + namespace + revision`；四项都参与 equality/hash。图片使用 `kind=imageBytes`，详情/章节/搜索分别使用对应 response kind。 |
| `coverUri` / `coverSourceId` | 图片 locator | 只告诉 artwork gateway 去哪里取图；可能是 HTTP(S)、`mihon:resource:` 或本地 locator，本身不参与稳定漫画身份。外部封面响应使用 `[sourceId, canonicalComicId, role=cover]`，URL变化不会分裂 namespace。 |
| `previewUri` | 预览项 locator 和绘制身份 | 详情预览完整 URI（包括 Venera `@x/y` 裁剪后缀）保留在预览项、widget 和 painter 中；编码字节缓存及实际请求使用去掉 `@x/y` 的 base URI。 |
| `resourceRole` | 漫画图片角色 | 封面为 `cover`；详情预览为 `preview:<base previewUri>`；其他带 URI 的 artwork 角色同样使用 base URI。外部 artwork 响应 key 使用 source + canonical comic identity + role；raw comic ID 只传给 runtime loader。 |

### 11.2 同源版本与迁移身份

同源版本必须区分以下身份，任何一层都不得用标题或 URL 字符串替代：

- **raw locator identity**：`sourceId + raw comicId`，是插件请求、SavedComic、章节归属和迁移前后实体的真实定位身份；同一来源的新旧版本必须保留不同 raw comicId。
- **canonical comparison identity**：来源确认的同源等价比较值，只用于归并重复投影和比较候选；它不能替换 raw locator，也不能直接改写章节、页面或下载 key。
- **version relation identity**：`sourceId + predecessorComicId + successorComicId`。关系必须由 `ComicVersionSource` 或已持久化的来源确认结果产生；标题搜索结果不能自动成为版本关系。
- **chapter/page identity**：章节始终为 `sourceId + chapterId`，Reader 页面为 `sourceId + comicId + chapterId + pageId`。迁移时只有章节原生 identity 精确匹配才复制阅读进度和已读状态；**sequence-only** 匹配仅显示在比较报告中，不复制状态。
- **presentation identity**：Flutter key、详情提示和 Reader 一次性提醒只能引用上述稳定复合身份；Widget key、当前章节、封面 URL、按钮状态和 runtime adapter 对象都不是持久身份。

同源 successor 发现后先写入 `ComicVersionRelationStore`，并可从 successor 反查多个 predecessor。详情页分别提供“查看新版本/查看旧版本”和“迁移”；查看只打开目标 raw identity 的详情，multiple versions 先选择，不修改版本关系或阅读历史。Reader 仅在已保存 successor 关系存在时首次提醒，不在进入 Reader 时联网。确认迁移后，新 raw locator 成为新实体；旧版本的离线字节不按 URL 或页码盲目迁移，只有 checksum/source page key/content hash 支持的 artifact 才允许复用。

稳定响应 key 的编码由 `encodeStableCacheKey` 负责：使用 `zic-key-v1:` 前缀和长度前缀组件，
因此 URL 中的 `/`、`:`、`@` 等字符不会造成分隔符碰撞。当前图片 key 的实际关系如下：

```text
sourceId + canonical comic identity
  -> durable comic/artwork namespace
  -> imageBytes / comic-response(role) / revision

raw comicId
  -> plugin runtime locator / chapter ownership / Reader identity only

封面:
  [sourceId, canonicalComicId, role=cover, revision=artwork-v2]

详情预览:
  [sourceId, canonicalComicId, role=preview:<base previewUri>, revision=artwork-v2]
  完整 previewUri -> cache/request 使用去掉 @x/y 的 base URI
                    -> App widget/painter 仍按完整 URI 的 @x/y 裁剪

持久化文件:
  hash(kind + identity + namespace + revision)
  + 文件记录再次校验完整 ResourceCacheKey
```

首页/详情 artwork 的缓存层顺序是 memory -> durable byte store -> source loader。durable命中先读取为
由 presentation 持有的 `Uint8List`，不会把 cache-managed文件路径交给 `FileImage`。持久 artwork 的
**身份**与**保留生命周期**是两个维度：来源 browse/preview 等临时响应属于 `transient`，可受 TTL/LRU/
maintenance 容量回收；已进入 library/history/details 持久语义的 cover在同一个 `ResourceCacheKey` 上
单调晋升为 `retained`，不参与运行期容量/TTL淘汰，只能由精确 artwork revision失效、漫画资源显式删除
或用户清缓存移除。晋升不能创建第二 namespace。内存 response plane仍保持有界，presentation已取得的 bytes
也不依赖 durable entry继续存在。source-independent warm probe命中时，首页封面不会解析来源或启动插件；
miss才进入 gateway/source transport。
因此预览图的完整 URI 仍决定每个 widget 的裁剪区域，但同一 base URL 的编码字节只保留一份，
避免旧实现按每个 `@x/y` 裁剪重复请求和占用缓存。旧的每裁剪项 role 不会与新的 base role 相同，因此无需迁移预览裁剪缓存。封面 durable
namespace 由 canonical comic identity 固定，raw Mihon `comicId`、封面 URL、详情补全后的 SManga
字段变化都不得创建第二个 namespace。`comicArtworkCacheSchemaRevision` 由 resource cache/gateway
统一拥有；external artwork调用方只能提供可选 content revision，不得再次传入基础 schema revision，
否则会把 browse 与 details/history 分裂成 `artwork-v2` 和 `artwork-v2:artwork-v2` 两套 namespace。
封面内容版本变化由 content revision/精确 artwork refresh处理，不能通过 presentation State、provider eviction
或新的 raw alias 隐式换 key。catalog details/chapter刷新只能失效 metadata；不得因共享 comic namespace
顺带删除 retained artwork。整漫画资源删除是独立的显式生命周期操作。

图片加载失败的边界必须分开：cache hit/miss 只说明编码字节是否存在；source loader 的失效路径、非图片响应、权限/challenge/空响应由 gateway 拒绝；Flutter decode 错误只影响 presentation。单张失败的 Trace 至少记录脱敏 `sourceId/raw comicId/resourceRole/URI`、cache origin 和 transport/decode 错误，不能仅凭占位图判断缓存冲突。

### Reader checkpoint 与历史投影边界
Reader 页面变化只 enqueue 最新 `ReadingProgress`，不得等待 SQLite或逐页发布 Home；storage isolate 对同 source/chapter latest-wins，空闲约 8 秒提交、持续活跃最多约 30 秒提交。显式 `saveProgress()`/store close 可等待内部 durability barrier，但 Reader route API不暴露 barrier。
Reader 返回后 Home只更新该 route最终 progress一次，已挂载详情只替换当前章节；不得在返回路径读取/重建整库。硬进程终止仍为 best-effort，不宣称最后一页绝对持久化。

## 12. 插件与网络边界

网络默认 User-Agent 属于 composition-owned 请求策略。AppPreferences 保存当前 fallback UA，默认使用稳定 Android Chrome UA；`main`/composition 以动态 provider 注入通用 `HttpTransport`、Reader/章节下载 fallback、插件仓库 control-plane 与 shared source host transport。来源 request plan 显式 `User-Agent`、Mihon browser-session UA或 source-owned client策略拥有更高优先级，全球设置不得覆盖这些来源权威。Presentation 不得自行构造 HTTP client。

网络执行只有三类合法 owner：

- **source-owned client**：Mihon/Venera 等来源的 CookieJar/interceptor/auth/DNS/TLS/session 语义；未知 client wrapper、重定向、`Set-Cookie` 或无法无状态平铺的响应必须留在这里执行；
- **统一 host transport**：仅重放来源已经解析成无状态 request plan 的单次资源请求。host replay关闭自动 redirect，只有无 Cookie 状态变化且直接返回编码媒体时才有资格把字节交给 Pipeline；
- **control-plane HTTP**：插件仓库索引/APK/JS安装等，不属于漫画 response cache，但仍使用 composition 的默认 UA fallback。

`ResourceCacheManager` 是可重新获取 metadata/artwork response 的唯一缓存 owner。Catalog browse/details只管理 metadata，`CachedBrowsableComicSource` 不提供 artwork loader facade；封面、预览不得直接取得 raw source transport。章节正文/Reader page body 明确由 DownloadSession/artifact/Pipeline 管理，因此通过 `ComicSourceResourceGateway.pageResponseLoaderFor/loadPageBytes` 绕过 response cache。两者必须复用同一 source-resolved response loader；full-byte fallback不得直接调用 `source.loadResource()`。章节下载侧只接受原子 `ChapterResourceAccess`，不得分别更新 byte loader 与 streaming transport。

插件先生成 request plan。GET/HEAD 必须零 body且不得携带实体 headers。Mihon 页面资源必须从 `HttpSource.imageRequest(page)`（或等价 source request）保留准确 URL、method、headers和必要的小型 request body；共享 transport不得注入 Venera专用默认 UA。Android宿主必须提供可执行 source实际返回 HTTP(S)媒体 URL 的统一网络能力，不能按具体插件/域名维护 cleartext白名单或擅自 HTTPS改写；URL选择仍属于 source/request plan。宿主直连前同步投影当前 source OkHttp CookieJar Cookie与同站点 browser-session UA。若宿主 HTTP成功但响应前缀不是支持的编码图片，字节不得进入 Pipeline/decoder，而应使用已有 source-owned runtime network兼容路径；普通可重放图片仍由宿主流式 transport进入统一 Pipeline，完整图片正文不得仅因 Cookie/header需求改走 JSON/Base64 RPC。页面下载的 retry只有 `LiveCoordinator` 一个 owner：runtime transient错误必须投影为 `ErrorCode.network`后进入有界重试；非 retryable/source错误或重试耗尽在当前 demand内成为 terminal，source listener/finally不得自行重复提交。

Cloudflare 可见浏览器的 Cookie 与 User-Agent 必须属于同一个浏览器 session。验证模式下 `NetworkBrowserActivity` 不得把插件/OkHttp 的静态 UA 写入 WebView；WebView 使用当前 Android WebView provider 的真实 UA，并把该 UA 与同站点 Cookie/localStorage 写入同一 snapshot revision。Mihon runtime 读取 snapshot 时不再要求它等于启动前的静态 UA，而是在 OkHttp application interceptor 中对同站点请求逐请求采用 snapshot UA；CookieJar 同步导入同一 revision 的 Cookie。这样避免 `cf_clearance` 来自真实 WebView、HTTP 请求却继续声明另一浏览器/平台所产生的 Cloudflare 指纹不一致。

`sourceVerificationRequired` 只由 host-owned typed `SourceVerificationRequiredException` 产生。`cf-mitigated: challenge` 是明确协议证据；否则 HTTP 状态必须为 403/503、`Server` 必须是 Cloudflare，并且 HTML 必须含 Mihon 同样使用的 `challenge-error-title` 或 `challenge-error-text` 实际交互 challenge DOM。仅出现 `challenge-platform`、`cf-chl-*`、`Just a moment`、Cloudflare Server header或普通 403/503都不足以触发浏览器验证，避免把 geo/access block误分类为可通过 WebView解决的验证码。异常 envelope 同时携带实际失败 request URL、HTTP 状态和请求时 `cf_clearance` 是否存在；这些字段只用于恢复路由和诊断，不进入持久 identity。Mihon 主网络和 ABI兼容 interceptor均委托同一个 detector；不得创建隐藏 WebView、等待 challenge或按异常消息文本猜测。

插件和平台桥不得导航、创建 Reader、提交 demand、直接读写 artifact、访问 App controller，或把 Cookie/token/Base64 payload 原文写入 Trace。

## 13. Telemetry 与关闭

状态所有者产生权威事件；App 只做有界导出。长 identity 使用 hash/长度摘要，高频事件可合并，但错误、retry、writer rejection、session retain/reuse 和生命周期边缘不得丢失。overlapping total 不得与子阶段重复参与 dominant 归因。

完整关闭遵循依赖逆序：停止新 demand，关闭 upload/decode/download，释放 frame/output/texture，关闭 runtime scheduler与 workspace，最后由 App 关闭其创建的平台 facade。外部注入 capability 不由消费方关闭。

## 14. 静态门禁

静态门禁阻止明显的依赖反转、API 泄漏、重复权威和文档漂移，但不能替代 `flutter analyze`、Dart/Flutter/Rust tests、Android debug/release build 和真机生命周期/性能验证。
