# ADR 0124：首页封面独立前台完成与后台持久化

**状态：Provisional**

## 背景

首页的 `ComicCoverCard` 已经按卡片分别创建 loader，但冷 miss 经过
`ResourceCacheManager.getOrLoadEncodedImage()` 时，前台 Future 还会等待响应字节写入
durable store，并再次等待全局持久化队列确认文件位置。多个封面共享该串行队列时，快速
封面也可能和慢封面成批出现，造成“所有封面 request 完成后才显示”的体验。另一方面，
首页远程封面在进入 response cache 前先解析 source；书架使用 `IndexedStack` 时还会把
未选中的页面一起构建，产生额外的封面 loader。

## 决策

1. `ResourceCacheManager.getOrLoadEncodedImage()` 保留默认的
   `awaitPersistence: true` 合同，保证需要 durable file origin 的调用继续等待写入完成。
2. 首页封面前台路径通过 `awaitPersistence: false`：源字节返回后立即交给
   `MemoryEncodedResourceSource`/Flutter 图片解码；durable write 仍进入同一个缓存 owner
   的持久化队列，不由 Widget 自行管理。
3. 已存在的 durable file 命中仍直接返回 `FileEncodedResourceSource`，不改变 warm start
   的文件读取优化；`ResourceCacheManager.close()` 继续等待 active load 和持久化队列。
4. 只有首页 artwork gateway 和首页 content URI 路径使用非等待模式；通用 catalog
   `loadImageSource()` 默认保持等待，以免改变需要文件源的其它调用者。
5. 首页 artwork gateway 先探测 source-independent raw stable image key。命中时不解析
   source、不创建 plugin transport；raw miss 才进入真实 source loader，并写入当前 raw
   stable key。dev.135 为 app 更新保留的旧 URL-derived/canonical key 读取、byte-copy 和
   alias 回填全部删除；封面 revision、artifact alias/rekey 和版本更新复用仍由各自 owner
   保留。
6. 来源确认过的 canonical comic identity 写入 `SavedComicRecord`，只用于插件未激活时
   的书架只读归并。raw comic/chapter identity、请求 locator 和章节所有权不被改写。
7. 首页、书架、来源和杂项导航使用 lazy indexed page：未访问页面只保留零尺寸占位，首次
   访问后保留页面节点和状态；隐藏页面不提前创建封面卡片。

## 后果

- 单张快速封面不再被另一张慢封面或前一张持久化写入挡住，封面可以渐进显示。
- 首次冷 miss 首先使用内存 encoded source；进程重启后仍可命中 durable file。
- 持久化错误仍由 cache diagnostic callback 归因，不能使已经可显示的封面 Future 失败。
- 前台和 durable 写入的结果是有意分离的；测试必须分别覆盖“先显示”和“关闭排空”。
- 旧 app-update cache key 不再读取；已有旧条目按当前 stable key miss 处理并在真实 source
  loader 完成后写入当前 key。这样不会让插件兼容路径成为首屏缓存命中条件。
- canonical alias 只影响书架读模型的归并；持久化记录、raw request identity、chapter
  ownership 和 artifact/version reuse 不被删除或重写。
- 页面懒构建会推迟非当前导航页的 widget 初始化，但首次访问后的页面状态继续保留。

## 验证边界

已增加 ResourceCacheManager 的阻塞写入测试、raw cache-first/obsolete-key gateway tests、
两张封面一快一慢的 App widget test，以及未访问书架不启动封面 loader 的回归测试，并
增加持久化 canonical alias 的书架归并回归测试；并通过受影响 owner tests。目标设备仍需用真实 Home Trace 对比首张与后续封面的
`homeCoverSourceReady`/`homeCoverFirstFrame` 间隔，因此本 ADR 保持 Provisional。
