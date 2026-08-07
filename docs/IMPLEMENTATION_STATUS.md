# zic Implementation Status

**源码版本：** `0.31.0-dev.149`
**App build：** `0.31.0+149`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0` 和 `versionCode=148`。
- 首页先发布章节投影与 SavedComic primary 数据，封面不等待分类、偏好和阅读状态 enrichment。
- 冷启动先呈现 App/Bootstrap；native media prewarm、整本队列 restore 和外部插件 activation
  不阻塞 Home primary，外部 source ready 后增量接入；失败封面仅按稳定资源 identity、显式 retry revision 或 App resume 恢复，loader closure identity 不参与重试。
- 首页封面按卡片独立完成；前台 cold miss 在 encoded bytes 到达后立即返回 memory source，
  durable response 写入后台排队，warm durable file hit 仍直接返回文件源。 首页、漫画源卡片与详情封面在 source Future 瞬时失败时使用有界重试；Flutter 解码失败只驱逐对应 provider 并重建 ImageStream，App resume 时可再次恢复，不清空统一 response cache。
- 首页 artwork 先查 source-independent raw stable key；raw hit 不解析 source/plugin，
  raw miss 才进入 source loader。dev.135 为 app 更新保留的 URL-derived/canonical 旧 key
  兼容读取已删除。来源确认过的 canonical comic identity 会持久化到 SavedComic 元数据，
  让冷启动在插件未激活时也能只读归并同源旧/新 raw ID；首页/书架等导航页 lazy 构建，
  首屏不再创建隐藏页面的第二套封面 loader。
- 详情页 AppBar 不再保留旧版本/迁移图标。正文中的版本卡按 VibeVenera 逻辑分别提供“查看新/旧版本”和“迁移”；多个版本先选择。查看使用临时 route identity，持久阅读历史仍按各 raw source/comic identity 分离；迁移继续使用原严格比较确认 UI，只有 exact chapter identity 复制阅读状态。Reader 对每个 source/predecessor/successor 仅首次提醒。
- App-owned modal panel 的操作行统一使用左下角 X 关闭，右侧保留确认/保存/删除动作，
  已移除取消文字按钮。
- Venera 运行时登录请求已兼容 Android 解码后的嵌套 Map，不再把 credentials/cookies/web
  登录参数错误判为 `runtime-request-invalid`。详情 manifest 已接入 Venera `subId`、首批
  thumbnails/comments；支持的来源显示预览栏、评论栏、分页评论页和回复页，图片仍走
  统一 artwork cache，未声明能力的来源不会触发对应插件请求。
- 漫画源浏览页使用来源自有 section：Mihon Popular/Latest、Venera explore/category；来源生态仅以 chip 背景色区分，不显示 JS/插件图标。切换 source 时先按目标请求 identity 投影目标缓存，精确缓存缺失时使用目标 source 最近缓存，绝不保留旧 source 卡片。页码位于滚动尾部，左下浮动搜索保留持久历史；展开搜索优先消费返回和垂直滑动手势，Mihon `getFilterList()` 的 CheckBox/TriState/Select/Group 子项以 opaque 过滤标签显示。catalog 缓存先显示、后台刷新且数据不变时不重建；边缘下拉达到阈值后保留当前列表执行强制来源刷新。Mihon 已安装与仓库插件列表继续按声明/source metadata 的规范化语言筛选。
- 详情页与漫画源页共用同一个可见的顶部边缘下拉刷新组件：`onEdge`、位移 72、保留旧内容后台刷新。
- Android 可见浏览器 Cookie snapshot 以 `updatedAt` 为 revision，每个 runtime 进程/站点/UA 只导入一次。WebView 验证返回后目标 source 会重启；新 Mihon runtime 清空进程内 import revision，使第一个真实 request 按实际 host/UA 导入最新同站 snapshot。平台 runtime 对 retryable lifecycle response 原地重新激活并重试一次；已打开详情页按稳定 source ID 解析当前 adapter。
- Mihon runtime 通过稳定 `AndroidCookieJar.resetBrowserSnapshotImports()` 清理进程内 browser-snapshot revision；`AndroidBrowserCookieSession` 不再是 plugin host直接依赖或 common runtime ABI项。APK metadata reader可解析字符串资源形式的 extensionLib/entry class，并支持多个 entry class分隔。设备发现合并系统包、应用列表与仓库 package name精确探测，逐 APK失败和扫描计数直接显示；页面打开会自动加载默认仓库以提供精确探测 identity。扫描仅覆盖系统共享 APK，Mihon 私有扩展需从 ZIC仓库安装。
- Catalog 的 `resolveComicWebUri` 装饰器与来源能力保持 `Uri?` 合同；来源无法提供详情 URL 时由调用方继续使用 descriptor website fallback。
- Reader 进度使用单 writer 合并队列；正常 route pop 等待最终 checkpoint，详情页返回后立即重新读取 snapshot。页面变化及 inactive/paused/detached 持续 best-effort checkpoint，异常进程终止不承诺绝对完成。
- App 已删除 synthetic“开始阅读/正文”清理。Mihon adapter 只删除与真实章节并存的独立开始阅读动作，单独“正文”gallery fallback 保留。
- Cloudflare 主路径与兼容路径统一委托 typed detector；仅严格 403/503 challenge 映射 `sourceVerificationRequired`，没有隐藏 WebView 或消息文本判断。
- catalog response cache 使用稳定 source/comic/chapter identity 和结构 weight；页面正文不进入该缓存。
- Home“更新漫画”已与阅读历史分离：只展示 `inShelf` 漫画并按 `SavedComicRecord.updatedAt`
  排序；Reader 在页码/模式变化、App lifecycle 暂停和 route dispose 时写入进度，
  `HomeLibrarySession` 即时替换内存记录。
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

- dev.145 将 2.5 秒首帧 watchdog 限制为同一 provider stream 的一次重建；无帧不再等价于 encoded cache 失效。Home 卡片 State 使用 section + comic identity，重复卡片共享 source Future/provider；只有明确 decoder exhaustion 才允许强制重读同一 cover identity。
- 远程详情现在先显示持久 catalog，再等待当前 active source；预览和评论每次调用重新解析 adapter。App 不再识别或清理 Mihon synthetic chapter identity；与真实目录并存的独立“开始阅读”动作只在 Mihon adapter 入 Catalog 前去重。
- 详情和漫画源刷新结果由同一个 `AppPullToRefresh` 定位；简介使用 Card，评论 HTML 换行转为普通文本，“继续”区增加上下间距。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| current-code documentation consistency gate | Verified-static |
| dev.75–dev.149 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Unverified：当前基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` |
| 受影响 Flutter owner tests | Unverified：当前环境没有 Flutter SDK；已补 owner tests，未执行 |
| Flutter analyzer | Unverified：当前环境没有 Flutter/Dart SDK |
| Android debug/release split APK | Unverified：当前环境没有完整 Android SDK/NDK |
| 设备性能与生命周期 | Implemented；待设备复验 |
| Verified-device | 无新增结论 |
