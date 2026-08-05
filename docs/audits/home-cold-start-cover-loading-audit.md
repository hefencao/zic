# 首页冷启动封面加载审计

## 范围与证据等级

- 范围：`main()`、App service composition、`HomeLibrarySession`、外部插件启动、
  持久整本队列 restore、`ComicCoverCard`、`ComicSourceResourceGateway`、导航页构建和
  `ResourceCacheManager`。
- 证据：Source-inspected；受影响 Flutter owner tests 和静态门禁为
  Toolchain-verified；尚无修复后目标设备 Trace，因此不下 Device-verified 结论。

## 根因

冷启动关键路径存在三类与首封面无关的等待：

1. `apps/app/lib/main.dart` 在 `runApp` 前等待 `prewarmDefaultLocalMediaPipeline()`。
2. `_openServices()` 在返回可承载 Home 的 `_AppServices` 前等待整本下载队列恢复，
   并 eager 激活所有已安装外部插件；后者还会进行 Android 设备扩展发现和隔离运行时
   准备。
3. `HomeLibrarySession` 发布 primary 后立即继续执行同步的 enrichment 查询和默认偏好
   写入。即使 primary 已 `notifyListeners()`，同 isolate 的后续工作仍可能让 Flutter
   首帧排队。

此外，插件 source 在 primary 首次构建时尚不可用会令封面 loader 失败；原来的
`_CoverImage.didUpdateWidget` 只比较稳定封面 identity，所以 source ready 后不会重试。

上一轮修复后仍存在一个更靠后的整体等待：`getOrLoadEncodedImage()` 的冷 miss 在
encoded bytes 已从来源返回后，还要等待 durable store 写入及其后的全局持久化队列定位。
多个首页封面共用该队列时，前台结果会被串行写入拖成批次，掩盖了卡片本身的独立
`FutureBuilder`。

日志还显示远程封面最终来源为 `durableCacheFile`，但原 gateway 在查 stable cache 前先
解析 source；因此 cache hit 仍被 source/plugin projection 的时序放在首屏路径上。首页
和书架由 `IndexedStack` 同时构建时，同一漫画会创建多个 `_CoverImage`，解释了本地漫画
数量之外还多一个未加载封面的现象。

## 修复

- 先 `runApp`，native media prewarm 改为后台任务。
- 增加 `createPersistentWholeComicDownloadQueue()`，App 不等待 queue `ready`；需要
  状态的 owner 继续等待同一个 Future。
- 增加 `ExternalPluginController.openDeferred()`/`ready`；Home 在 ready 后增量接入
  active sources，避免为 source replacement 重跑整库 reload。
- Home primary 发布后等待注入的首帧边界再进入 enrichment。
- 封面失败后，只有 loader 改变才触发一次重试，避免普通 rebuild 重复请求。
- 首页 artwork gateway 和 content URI 封面使用 `awaitPersistence: false`：字节到达即返回
  `MemoryEncodedResourceSource`，durable 写入继续由统一 response cache 后台排队；默认
  catalog/file-source 调用仍保持等待契约。
- 首页 artwork 先查 raw stable key；命中不解析 source/plugin。raw miss 才进入 source loader
  并写入当前 raw key；dev.135 为 app 更新保留的 URL-derived/canonical key 读取、byte-copy
  和 alias 回填已删除。file store 的 warm locate 不再因其它 key 的 persistence mutation
  被无条件短路。
- 来源确认过的 canonical comic identity 写入 SavedComic 元数据，书架在插件未激活时按
  comparison identity 做只读归并；raw request/chapter identity 和 artifact/version reuse
  不被改写。
- 导航页改为 lazy indexed page，首次未选中的书架/来源/杂项只保留占位，避免隐藏页面创建
  第二套 cover loader；访问过的页面状态继续保留。

## 验证

- `flutter test test/home_library_session_test.dart test/library_ui_test.dart`：通过。
- `flutter test test/downloads_bridge_test.dart`：通过。
- `flutter test test/external_plugin_controller_manifest_test.dart`：通过。
- `python3 tool/check_repo.py`、`check_dart_structure.py`、`check_documentation.py`、
  dev.96/dev.137/dev.139 门禁：通过。
- ResourceCacheManager owner test：阻塞 durable write 时前台 encoded image 仍先返回；
  App widget test：一张封面挂起时另一张先显示、未访问书架不启动封面 loader、raw cache hit
  不触发资源读取、obsolete canonical key 不被读取、持久化 alias 在插件未激活时只显示一张：
  通过。
- 受影响 App source analyzer 已运行，相关 3 个 source 保留 14 个既有 info/warning
  （包括 part extension protected-member、未使用方法、弃用 API 和已有 import 提示）；
  App 全量 analyzer 共 51 个既有 info/warning，故整体退出码非零；catalog analyzer
  无问题，resource_cache 仅保留 1 个既有 info。

## 待验证

- 目标设备冷启动中 `homeServicesReady → home-library-primary → homeCoverRequested →
  homeCoverSourceReady/homeCoverFirstFrame` 的真实时序，以及快慢封面是否按卡片独立推进。
- 有大量持久章节、已安装 Mihon/Venera 插件和 durable cover file 的冷启动对比。
- 目标设备需确认 raw durable hit 时 `homeCoverSourceReady` 之前没有 plugin resource
  request，并确认已持久化 canonical alias 的同源 raw ID 在插件 ready 前只显示一张。
- native-enabled Android debug/release APK 与真实设备内存/帧调度影响；本轮已用
  `ZIC_ANDROID_NATIVE=0` 构建两种 split APK。
