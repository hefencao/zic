# zic Implementation Status

**源码版本：** `0.31.0-dev.140`
**App build：** `0.31.0+140`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。本快照没有新增 `Verified-device` 结论。

## 当前实现

- debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0` 和 `versionCode=140`。
- 首页先发布章节投影与 SavedComic primary 数据，封面不等待分类、偏好和阅读状态 enrichment。
- 冷启动先呈现 App/Bootstrap；native media prewarm、整本队列 restore 和外部插件 activation
  不阻塞 Home primary，外部 source ready 后增量接入，失败封面可随 loader 变化重试。
- 首页封面按卡片独立完成；前台 cold miss 在 encoded bytes 到达后立即返回 memory source，
  durable response 写入后台排队，warm durable file hit 仍直接返回文件源。
- 首页 artwork 先查 source-independent raw stable key；raw hit 不解析 source/plugin，
  raw miss 才进入 source loader。dev.135 为 app 更新保留的 URL-derived/canonical 旧 key
  兼容读取已删除。来源确认过的 canonical comic identity 会持久化到 SavedComic 元数据，
  让冷启动在插件未激活时也能只读归并同源旧/新 raw ID；首页/书架等导航页 lazy 构建，
  首屏不再创建隐藏页面的第二套封面 loader。
- 详情页 AppBar 不再重复显示漫画标题；保存过进度时提供可操作的药丸形“继续”按钮，
  阅读历史与按钮同一行并位于章节总数行上方，带时钟图标。详情页提供同源版本入口和迁移入口，Venera 版本入口
  复用运行时网络/Cookie 按 `#gnd` 关系读取，不再走标题 browse；迁移面板显示当前
  插件/来源，并允许同一 source 下不同原生 comic ID 的版本替换；目标写入和章节身份校验
  完成后才清理旧版本记录；已发现的新版关系写入 `ComicVersionRelationStore`，迁移面板会显示旧版。
- App-owned modal panel 的操作行统一使用左下角 X 关闭，右侧保留确认/保存/删除动作，
  已移除取消文字按钮。
- Venera 运行时登录请求已兼容 Android 解码后的嵌套 Map，不再把 credentials/cookies/web
  登录参数错误判为 `runtime-request-invalid`。详情 manifest 已接入 Venera `subId`、首批
  thumbnails/comments；支持的来源显示预览栏、评论栏、分页评论页和回复页，图片仍走
  统一 artwork cache，未声明能力的来源不会触发对应插件请求。
- 漫画源浏览页已按原生/Mihon/Venera 分类，并改为显式上一页/下一页；Mihon 已安装与仓库插件列表按声明/source metadata 的规范化语言筛选。
- catalog response cache 使用稳定 source/comic/chapter identity 和结构 weight；页面正文不进入该缓存。
- Home“更新漫画”已与阅读历史分离：只展示 `inShelf` 漫画并按 `SavedComicRecord.updatedAt`
  排序；Reader 在页码/模式变化、App lifecycle 暂停和 route dispose 时写入进度，
  `HomeLibrarySession` 即时替换内存记录。
- 详情预览保留完整 URI 作为单项绘制身份，但 artwork role/cache key 使用去 `@x/y` 的 base URI，
  同一原图的不同裁剪共享一份编码字节；Venera `loadThumbnails` 的首批与游标分页
  不再重复消费 `loadInfo` 缩略图；折叠与展开共用按原顺序生成的等目标面积布局，面积比不超过 1.2，折叠高度取第一行，展开图片区域不超过屏幕高度 80%，居中箭头控制展开；点击预览项会将索引传入既有 Reader 路由；Venera
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

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart static gates | Verified-static |
| current-code documentation consistency gate | Verified-static |
| dev.75–dev.139 ownership gates | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI contracts | Verified-static / toolchain |
| Kotlin texture bridge compile stub | Verified-toolchain |
| pinned libwebp host build/smoke | Verified-toolchain |
| 受影响 Flutter owner tests | Verified-toolchain：继续阅读、迁移对话框和同源 comic ID 迁移单测通过 |
| Flutter analyzer | Unverified：App 全量 analyzer 保留 51 个既有 info/warning，整体退出码非零 |
| Android debug/release split APK | Verified-toolchain：`ZIC_ANDROID_NATIVE=0`；native-enabled path 未验证 |
| 设备性能与生命周期 | Implemented；待设备复验 |
| Verified-device | 无新增结论 |
