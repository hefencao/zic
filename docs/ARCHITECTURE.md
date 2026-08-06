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

领域 identity、值对象和不可变实体。不得依赖 UI、插件、网络、缓存、数据库或平台桥。

### `catalog`

漫画源、漫画/章节/page manifest、来源能力和 catalog cache identity。`CachedBrowsableComicSource` 只缓存目录响应；Reader 页面正文仍透传到统一 Pipeline。

### `resource_cache`

封面、详情、搜索、章节元数据等可重新获取响应的唯一缓存平面，拥有容量、TTL、分类预算、in-flight 合并、持久 byte store 和失效策略。

### `transport`

可取消、可分块的 encoded-byte transport、range、validator 和 response 合同。它不拥有 artifact、Reader demand 或播放状态。

### `storage`

partial artifact、连续前缀、校验、seal、原子 promotion、索引和临时 workspace。它不决定页面角色或网络优先级。

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
首帧边界，再读取 enrichment 和写入缺失默认值。封面 encoded-source Future 与 Flutter
ImageStream 是两个恢复边界：传输失败由卡片有界重试，解码失败只驱逐对应 provider 并重建
ImageStream；App resume 时失败项可再次恢复。普通 Widget rebuild 不产生第二套封面
请求权威。首页 artwork 的冷 miss 在 encoded bytes 到达后先返回 memory source，durable
response 写入由 `ResourceCacheManager` 后台排队；同一批封面按卡片独立完成，不等待全部
封面或全部持久化写入。首页 artwork gateway 只用 source-independent raw stable comic
key 探测 response cache；命中时不解析 source、不创建 plugin transport。raw miss 才进入
真实 source loader，且仍写回 raw stable key；当前生产路径不读取 dev.135 的旧
URL-derived/canonical app-update key。来源确认过的 canonical identity 写入
`SavedComicRecord`，只用于插件未激活时的书架只读归并，raw request/chapter identity 不被
改写。未访问的
首页、书架、来源和杂项页由 lazy indexed page 保持未构建，避免隐藏导航页提前创建第二套
封面 loader；访问过的页面状态仍由该页面节点保留。

Home 的“更新漫画”投影只取已在书架中的漫画，并按持久化的漫画元数据更新时间排序；阅读历史
单独按 `ReadingProgress.updatedAt` 投影，阅读进度不会再把非书架漫画或普通阅读行为混入更新列表。

### 详情页与来源迁移组合

`ComicDetails` 只把详情展示、阅读进度和用户命令投影到 Flutter；详情 AppBar 不重复显示
漫画标题，标题只在详情内容区出现。保存过阅读进度时，继续阅读命令直接调用既有
`onOpenChapter` facade，按钮和阅读历史是两个独立的 UI 投影，并位于章节总数行上方；详情页不创建第二个阅读器或
正文缓存。来源浏览、manifest/chapter 身份校验、状态迁移和 artifact 复用由
`_DemoHomeSourceMigration` 组合 owner 完成。

同源版本入口优先使用来源暴露的 `ComicVersionSource`；Venera 适配器复用自身运行时网络与
Cookie 会话，按当前详情页 `#gnd` 关系生成版本，不把 Venera 当作标题 `browse` 搜索，避免
触发浏览器权限错误。来源确认的前后版本关系由 `ComicVersionRelationStore` 持久化，因此当前
新版详情页也能显示已发现的旧版；没有来源专属版本能力时才回退到普通 `browse` 候选。迁移计划允许相同
`sourceId` 下不同的原生 `comicId`，因此可处理 E-Hentai URL/gallery locator 变化。迁移只复制
经过精确章节匹配验证的偏好、阅读位置和已读状态，并先完成目标写入；同源替换随后清理旧漫画
记录，跨源迁移保留原来源。迁移面板始终展示当前插件和来源，目标可为当前来源或其他已启用来源。

漫画源页使用来源自身声明的 browse section：Mihon 映射 Popular/Latest，Venera 枚举 explore loader 与 category target；原生/Mihon/Venera 仅通过来源 chip 的颜色与图标区分，不占内容分类行。固定大小的 catalog page 仍使用显式上一页/下一页，但 pager 位于内容滚动尾部。左下浮动搜索位于来源栏上方，展开后显示持久化搜索历史；展开面板优先消费返回和垂直滑动手势，收起后才把手势交还页面。Mihon `getFilterList()` 由 runtime adapter 投影为 opaque `SourceSearchFilterOption`，搜索框上方仅显示 CheckBox、TriState、Select 与 Group 子项的过滤标签，UI 不解析插件对象。列表由 catalog response cache 先行投影，后台 refresh 只有在稳定字段发生变化时才更新 Presentation；边缘下拉达到刷新阈值后强制绕过缓存请求来源，但保留当前内容直到新数据到达。Mihon 插件的已安装与仓库列表仍按规范化语言分类。

详情扩展数据由 source adapter 负责：`ComicManifest` 可携带首批预览缩略图和评论，
`ComicPreviewSource`/`ComicCommentSource` 只在来源声明能力时提供继续分页。App 只消费
规范化 URI、评论字段和不透明的 `sourceSubId`/回复 ID；图片仍走统一 artwork cache，
评论完整列表和回复通过详情次级页加载，不把评论请求或插件 transport 变成章节目录的
全局门控。Venera 直接复用 `comic.loadThumbnails` 与 `comic.loadComments`，因此已有
`ComicDetails` 能力的来源可渐进显示预览、评论和回复。预览 URI 保留 Venera 的
`@x/y` 裁剪标识用于预览项/widget/painter 的单项身份，但 `onThumbnailLoad` 请求回调接收
去掉裁剪标识的原图地址；该 base URI 也是编码字节缓存身份，App 解码后只绘制对应裁剪区域。
预览栏折叠与展开共用同一套顺序布局。布局按原始预览顺序逐行装箱，每张缩略图先使用等目标面积并按自身宽高比计算宽高；随后按行受限放大并把剩余空间分配到项间距，使完整预览行尽量贴近屏幕左右边缘而不浪费竖屏宽度。所有行的缩放跨度受 `sqrt(1.2)` 限制，因此同一布局中最大与最小显示面积比不超过 1.2；阅读设置提供每行最大数量 1–8，默认 4。折叠态只裁出该布局第一行，高度直接取第一行高度；展开态继续消费来源分页，并由 `PageView` 左右分页呈现后续行。展开图片区域按屏幕高度 80% 封顶，开关位于中间且只显示上下箭头。行规划优先使用 `ComicPreviewAsset.width/height`，缺失时以解码后的可见裁剪尺寸回填；缩略图使用 `BoxFit.contain`，不拉伸或强制裁切。预览失败只显示按资源 identity 生成的柔和单色占位，不显示破损图片图标。

App-owned modal panel 的操作行由 `AppDialogActions` 统一投影：关闭固定为左下角 X，确认、
保存或删除位于右侧，不再使用“取消”文字按钮。

### 插件与平台桥

- `plugin_host`：信任、权限、请求计划、身份适配和插件生命周期。
- `plugin_host_bridge`：Android 隔离进程与 Mihon/Venera runtime 适配。
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
`reader_runtime` 在页码/阅读模式改变时通过既有 progress facade 写入进度，并在 App lifecycle
进入 inactive/paused/detached 或 Reader route dispose 时强制 flush；`HomeLibrarySession` 立即替换
内存投影，因此退出 Reader 即可刷新历史和相关 Home 投影，不再等待详情父路由销毁。

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
- priority 提升原位迁移，差值达到 40 时可抢占低优先级 active task；
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

## 11. Identity、缓存与 artifact

不同 identity 层不可混用：catalog identity 定位实体；DownloadId 表示确定字节版本；DecodeId 还包含 epoch、target 和 renderer；presentation identity 只表示页面位置/输出。

缓存分为两个权威平面：

- `ResourceCacheCoordinator.responses`：封面、搜索、详情和章节元数据，使用稳定 namespace/identity/revision、weight、TTL 和 in-flight join；封面使用 raw comic stable identity 和 role，source-level artwork 使用版本化 source identity；
- `ArtifactCacheManager`：Reader 不可变页面 artifact，默认热字节 10 项/256 MiB、alias 上限 8192，并连接持久 backend。

封面 URL/token 不是稳定 comic identity；verified checksum、来源 page key、内容 hash 或用户确认迁移才可注册 artifact alias。App/Reader 不得创建私有图片字节 LRU，也不得让 cache hit 共享 cursor、timer 或 decode identity。

### 11.1 当前生产代码的 key/id 对照

以下是现有实现中容易被混称为“key”的几组身份。它们的用途不同，不能用标题、显示名或
图片 URL 互相替代。

| 名称 | 所有者/含义 | 当前组成和用途 |
| --- | --- | --- |
| `sourceId` | 来源身份 | 插件/来源的稳定 ID，不是来源显示名；参与 source namespace、漫画 namespace、`ContentId` 和资源请求绑定。 |
| raw `comicId` | 来源原生漫画身份 | `Comic`、`SavedComicRecord`、`LibraryComic` 和章节存储使用的原始漫画 ID。它可以是 URL 或 Venera 的 opaque locator；是前台封面在 source 未激活时仍可使用的身份。 |
| `LibraryComic.identity` / Flutter comic key | 书架实体身份 | 当前为 `sourceId\u0000comicId`（UI key 再加各自前缀）；标题、作者和封面 URL 都不参与。两个同名漫画只有在这组身份也相同才会被视为同一个实体。 |
| `canonicalComicId` | 来源确认的等价身份 | 仅由来源声明/确认的同源等价 ID，用于冷书架投影归并和 source-aware 元数据 namespace；不替换 raw `comicId` 的请求、章节或封面身份。旧 app-update URL-derived key 不属于当前生产读取路径。 |
| `chapterId` | 来源原生章节身份 | `Chapter`/`ChapterManifest` 的章节身份；章节元数据响应 key 使用 `[sourceId, chapterId]`，并挂到已知漫画 namespace。 |
| `pageId` / `PageAsset.assetKey` | 章节内页面身份 | `PageAsset` 保留 `pageId` 和 `chapterId`，`assetKey` 为 `chapterId/pageId`；它不是封面/预览响应缓存 key。 |
| `ContentId` | Reader 内容实体身份 | `[sourceId, comicId, chapterId, pageId]`，用于确定一个漫画章节页面；`ContentId.key` 只服务 Reader/download identity。 |
| `DownloadId` | 确定字节版本 | `ContentId + sourceRevision + canonicalUri`，用于 Reader 下载/artifact；页面 URL 变化或来源版本变化会形成新的确定字节身份。 |
| `DecodeId` | 解码输出身份 | `DownloadId + physicalWidth + physicalHeight + pixelFormat + renderer`；不参与首页/详情的图片响应缓存。 |
| `ResourceCacheKey` | 响应缓存实体身份 | 四元组 `kind + identity + namespace + revision`；四项都参与 equality/hash。图片使用 `kind=imageBytes`，详情/章节/搜索分别使用对应 response kind。 |
| `coverUri` / `coverSourceId` | 图片 locator | `Comic.coverUri` 或本地/导入记录里的 cover locator，只告诉 loader 去哪里取图；它不是 raw 漫画身份。对 `comicId != null` 的封面响应，当前 key 有意只使用 `[sourceId, comicId, role=cover]`，不把 URL 放入 key。 |
| `previewUri` | 预览项 locator 和绘制身份 | 详情预览完整 URI（包括 Venera `@x/y` 裁剪后缀）保留在预览项、widget 和 painter 中；编码字节缓存及实际请求使用去掉 `@x/y` 的 base URI。 |
| `resourceRole` | 漫画图片角色 | 封面为 `cover`；详情预览为 `preview:<base previewUri>`；其他带 URI 的 artwork 角色同样使用 base URI。它与 source/raw comic ID 一起进入图片响应 key。 |

稳定响应 key 的编码由 `encodeStableCacheKey` 负责：使用 `zic-key-v1:` 前缀和长度前缀组件，
因此 URL 中的 `/`、`:`、`@` 等字符不会造成分隔符碰撞。当前图片 key 的实际关系如下：

```text
sourceId + raw comicId
  -> comic namespace
  -> imageBytes / comic-response(role) / revision

封面:
  [sourceId, raw comicId, role=cover, revision=artwork-v2]

详情预览:
  [sourceId, raw comicId, role=preview:<base previewUri>, revision=artwork-v2]
  完整 previewUri -> cache/request 使用去掉 @x/y 的 base URI
                    -> App widget/painter 仍按完整 URI 的 @x/y 裁剪

持久化文件:
  hash(kind + identity + namespace + revision)
  + 文件记录再次校验完整 ResourceCacheKey
```

首页/详情 artwork 的缓存层顺序是 memory -> durable file -> source loader。source-independent
的 warm probe 命中时，首页封面不会解析来源或启动插件；miss 才进入 gateway/source transport。
因此预览图的完整 URI 仍决定每个 widget 的裁剪区域，但同一 base URL 的编码字节只保留一份，
避免旧实现按每个 `@x/y` 裁剪重复请求和占用缓存。旧的每裁剪项 role 不会与新的 base
role 相同，因此无需清空或迁移已有 cover 缓存；封面则有一个刻意的区别：同一 raw `comicId`
的 cover URL 改变会复用旧 cover key，表现为旧图/陈旧图，而不是 key 碰撞；应通过封面失效
或 revision 处理 URL 变化。

图片加载失败的判断边界也必须分开：

- cache hit/miss 只说明是否找到完整编码字节，不说明字节一定能被图片解码；
- source loader 可能拿到失效路径、非图片响应、权限/challenge 页面或空响应，gateway 会在
  `source artwork response is not an image` 处拒绝；
- cache miss 后的 source/plugin/transport 错误、URI 失效和 Flutter 解码错误最终都会被首页或
  详情 artwork widget 转成柔和单色占位，当前 Trace 若没有 artwork 事件，无法仅凭占位图区分；
- 当前 `.log/log.txt` 的证据是 Venera `loadComic/loadInfo` 在读取页面 DOM 时出现
  `Cannot read properties of null (reading 'children')`，这会阻断详情 manifest，但不是图片
  cache miss、图片路径错误或 `ResourceCacheKey` 冲突的证据。要定位单张失败项，Trace 必须同时
  记录脱敏后的 `sourceId/raw comicId/resourceRole/URI 摘要`、cache origin（memory/file/loader）
  和 transport/decode 错误。

## 12. 插件与网络边界

插件先生成 request plan。GET/HEAD 必须零 body且不得携带实体 headers。普通正文由宿主 transport 流式进入统一 Pipeline；完整 JSON/Base64 RPC 只允许用于明确声明 runtime transform 且有大小上限的兼容路径。

插件和平台桥不得导航、创建 Reader、提交 demand、直接读写 artifact、访问 App controller，或把 Cookie/token/Base64 payload 原文写入 Trace。

## 13. Telemetry 与关闭

状态所有者产生权威事件；App 只做有界导出。长 identity 使用 hash/长度摘要，高频事件可合并，但错误、retry、writer rejection、session retain/reuse 和生命周期边缘不得丢失。overlapping total 不得与子阶段重复参与 dominant 归因。

完整关闭遵循依赖逆序：停止新 demand，关闭 upload/decode/download，释放 frame/output/texture，关闭 runtime scheduler与 workspace，最后由 App 关闭其创建的平台 facade。外部注入 capability 不由消费方关闭。

## 14. 静态门禁

静态门禁阻止明显的依赖反转、API 泄漏、重复权威和文档漂移，但不能替代 `flutter analyze`、Dart/Flutter/Rust tests、Android debug/release build 和真机生命周期/性能验证。
