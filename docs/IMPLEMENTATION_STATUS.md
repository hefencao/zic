# zic Implementation Status

**源码版本：** `0.31.0-dev.157`
**App build：** `0.31.0+157`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0` 和 `versionCode=157`。
- 首页先发布章节投影与 SavedComic primary 数据，封面不等待分类、偏好和阅读状态 enrichment。
- 冷启动先呈现 App/Bootstrap；native media prewarm、整本队列 restore 和外部插件 activation不阻塞 Home primary，外部 source ready 后增量接入。
- artwork资源恢复唯一属于 `ComicSourceResourceGateway/ResourceCacheManager`。Home、书架、漫画源和详情 presentation 已删除定时 retry、first-frame watchdog、App resume自动 retry、全局 ImageCache eviction和 App级短时 Future join；同一 encoded source 只创建一个 ImageProvider；失败后保持稳定占位，显式来源刷新/资源 revision/稳定 identity变化才会重新加载。
- 外部 artwork 的 raw comicId只保留 runtime locator语义；durable cover/preview namespace使用来源 canonical comic identity。Home、漫画源、详情与迁移统一经 `ComicSourceResourceGateway`，`mihon:resource:` 不再误入本地文件 loader；gateway先查 source-independent durable cache，miss后才要求 active source。
- 详情页 AppBar 不再保留旧版本/迁移图标。正文中的版本卡按 VibeVenera 逻辑分别提供“查看新/旧版本”和“迁移”；多个版本先选择。查看使用临时 route identity，持久阅读历史仍按各 raw source/comic identity 分离；迁移继续使用原严格比较确认 UI，只有 exact chapter identity 复制阅读状态。Reader 对每个 source/predecessor/successor 仅首次提醒。
- App-owned modal panel 的操作行统一使用左下角 X 关闭，右侧保留确认/保存/删除动作，
  已移除取消文字按钮。
- Venera 运行时登录请求已兼容 Android 解码后的嵌套 Map，不再把 credentials/cookies/web
  登录参数错误判为 `runtime-request-invalid`。详情 manifest 已接入 Venera `subId`、首批
  thumbnails/comments；支持的来源显示预览栏、评论栏、分页评论页和回复页，图片仍走
  统一 artwork cache，未声明能力的来源不会触发对应插件请求。
- 漫画源浏览页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态仅以 chip 背景色区分，不显示 JS/插件图标。切换 source 时先按目标请求 identity 投影目标缓存，精确缓存缺失时使用目标 source 最近缓存，绝不保留旧 source 卡片。页码位于滚动尾部，左下浮动搜索保留持久历史；展开搜索优先消费返回和垂直滑动手势，Mihon `getFilterList()` 的 CheckBox/TriState/Select/Group 子项以 opaque 过滤标签显示。catalog 缓存先显示、后台刷新且数据不变时不重建；边缘下拉达到阈值后保留当前列表执行强制来源刷新。Mihon 已安装与仓库插件列表继续按声明/source metadata 的规范化语言筛选。
- 详情页与漫画源页共用同一个可见的顶部边缘下拉刷新组件：`onEdge`、位移 72、保留旧内容后台刷新。
- Android可见浏览器 Cookie snapshot以 `updatedAt` 为 revision。Cloudflare验证模式不再用插件/OkHttp静态 UA覆盖 WebView；当前 Android WebView provider的真实 UA与同站点 Cookie/localStorage写入同一 snapshot revision。Mihon `AndroidCookieJar` 同步导入该 revision的 Cookie，runtime application interceptor对同站点请求逐请求采用 snapshot UA，避免 clearance来自真实浏览器而 HTTP请求仍声明另一浏览器/平台。验证浏览器继续保留 dev.154 的稳定完成窗口与宽 challenge探针；手动或自动验证后若 runtime仍失败，普通刷新不再自动循环打开 WebView。验证返回后按稳定 source ID取得 replacement adapter。
- Mihon runtime 通过稳定 `AndroidCookieJar.resetBrowserSnapshotImports()` 清理进程内 browser-snapshot revision；`AndroidBrowserCookieSession` 不再是 plugin host直接依赖或 common runtime ABI项。APK metadata reader可解析字符串资源形式的 extensionLib/entry class，并支持多个 entry class分隔。设备发现合并系统包、应用列表与仓库 package name精确探测，逐 APK失败和扫描计数直接显示；页面打开会自动加载默认仓库以提供精确探测 identity。扫描仅覆盖系统共享 APK，Mihon 私有扩展需从 ZIC仓库安装。
- Mihon common runtime要求的 `SourceVerificationRequiredException` 已加入 network bridge consumer R8 keep规则；动态 ABI和 host在 minified Release中继续以同一原始类名共享 typed验证异常。门禁会从 required network class列表反查 keep覆盖。
- Catalog 的 `resolveComicWebUri` 装饰器与来源能力保持 `Uri?` 合同；来源无法提供详情 URL 时由调用方继续使用 descriptor website fallback。
- Reader progress保持 latest-wins有序 checkpoint，SQLite查询/章节JSON校验/写入位于独立 progress isolate + WAL connection。Reader热路径只入队；同章节 checkpoint停止更新约8秒时批量提交，持续阅读最多约30秒提交一次。Reader route不等待 durable barrier；返回后 Home只发布最终 progress内存投影一次，已挂载详情页只替换当前章节，不再全量 reload library。生命周期 checkpoint仍为 best effort。
- 来源漫画从 source页首次打开并持久化后，再次进入时外层 source route 已持有 raw comic identity；local SavedComic分支直接 `_pushComicDetails`，不再嵌套 `_openComicDetails` 重申请相同锁，因此不会静默吞掉第二次导航。
- Home阅读历史、详情和漫画源使用同一 external artwork gateway/cache identity；HTTP(S) 与 `mihon:resource:` 等插件 locator即使 source尚未激活也先查 canonical durable cache，只有 miss才解析 source。
- 外部插件 manifest按记录容错并保留上一代 `.bak`；启动可从 `.bak`、`.part` 或旧 `.invalid`恢复有效记录与旧 sandbox payload路径，再重写主 manifest。恢复失败逐项展示，不再因一个坏记录清空全部插件。
- Mihon chapter目录不再存在 synthetic/gallery fallback或标题去重。bridge先调用明确的 `get/fetchChapterList`；成功（含空）即权威，真实错误直接失败。只有该能力不存在时才调用 TachiyomiX 1.6 combined update，并传入已知章节原顺序。完全相同的非空 `SChapter.url`按 source locator折叠；显示标题不参与判断。
- Cloudflare 主路径与兼容路径统一委托 typed detector；仅严格 403/503 challenge 映射 `sourceVerificationRequired`，没有隐藏 WebView 或消息文本判断。
- catalog response cache 使用稳定 source/comic/chapter identity 和结构 weight；页面正文不进入该缓存。
- Home“更新漫画”与阅读历史分离：更新集合只按 `SavedComicRecord.updatedAt`；Reader checkpoint不逐页触发 Home rebuild，route返回后只用最终 `ReadingProgress`更新匹配的内存历史 entry一次。
- 详情预览保留完整 URI 作为单项绘制身份，但 artwork role/cache key 使用去 `@x/y` 的 base URI，
  同一原图的不同裁剪共享一份编码字节；Venera `loadThumbnails` 的首批与游标分页
  不再重复消费 `loadInfo` 缩略图；折叠与展开共用按原顺序生成的等面积布局；实际行内含横图时最多 2 张、纯竖图时最多 3 张；只在相邻三个候选内做最小局部重排，并受阅读设置的 1–8 项上限约束（默认 4）。完整行按全部媒体宽度反算尺寸，预览图片区不再叠加 Card 和水平 padding；稀疏末行最多放大到参考完整行面积的 2.4 倍；折叠高度取第一行，展开图片区域不超过屏幕高度 90%，居中箭头控制展开；点击预览项会将索引传入既有 Reader 路由；Venera
  `@x/y` 预览 URI 在保留绘制身份的同时按既有约定以去裁剪 URL 调用 `onThumbnailLoad`，封面、预览
  和来源缩略图失败时统一使用稳定伪随机的柔和纯色占位；预览绘制只显示 `@x/y` 指定的原图区域。
- ArtifactCacheManager 默认热字节 10 项/256 MiB，支持持久 backend、verified alias/rekey 和 foreground read join。
- Reader encoded window 为前 7/后 3；decode 角色为前 2/后 1；动态 holder 最大水位为 7/5/3/2。
- transition 覆盖率达到阈值后独立取得一帧，再恢复 current/neighbor staged refill；不存在 DownloadFlowGate、startup-buffer 或 holder-depth 网络资格门控。
- 页面网络由共享 NetLane 唯一调度：normal 5、current 高优先级保留槽 1、priority migration/preemption；local bucket 2、remote bucket 5。
- DownloadJob 首批约 16 KiB、后续约 64 KiB 合并 transport 小块；partial/resume、source growth 和 WebP prefix hints保持。
- holder-driven playback 在 successor 缺失时保持当前 output，使用 one-shot deadline wake；两个 decode isolate常驻，current 后续最多双帧批次。
- Android output 使用默认 platform channel、单 blit lane和普通 main-thread post；used texture 不跨 Reader 复用。
- Reader 资源会话最多保留 1 个 idle chapter、TTL 2 分钟；保留 resource session，释放 Reader binding、projection、playback wake 和 used texture。
- Native identity：`zic-media-core-dev134-abi6-lib00121400`；本轮不修改 Rust/JNI。
- 核心文档已按 production code 重新对齐；Reader 综合决策见 ADR 0122，Home 冷启动与
  封面前台完成见 ADR 0123/0124。

## 当前开放问题

- 目标设备仍需验证 transition 首帧、远程 WebP frame cadence、后台重入和首页首封面时序。
- 本轮首页冷启动修复仍需设备对比 `homeServicesReady`、`home-library-primary`、
  `homeCoverRequested`、各封面 `homeCoverSourceReady`/`homeCoverFirstFrame` 的真实间隔，
  并确认慢封面不会形成全局屏障；还需确认 raw durable hit 不触发插件资源请求，隐藏
  书架页不再产生重复首屏请求。
- Android APK 构建和真机生命周期验证未在当前环境执行。

- 详情和漫画源刷新结果由同一个 `AppPullToRefresh` 定位；简介使用 Card，评论 HTML 换行转为普通文本，“继续”区增加上下间距。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| current-code documentation consistency gate | Verified-static |
| dev.75–dev.157 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Unverified：当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` |
| 受影响 Flutter owner tests | Unverified：当前环境没有 Flutter SDK；已补 owner tests，未执行 |
| Flutter analyzer | Unverified：当前环境没有 Flutter/Dart SDK |
| Android debug/release split APK | Unverified：当前环境没有完整 Android SDK/NDK |
| 设备性能与生命周期 | Implemented；待设备复验 |
| Verified-device | 无新增结论 |
