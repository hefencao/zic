# dev.156 Reader进度、Mihon章节与Artwork根因审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.155_cloudflare-real-ua-history-plugin-recovery.zip`。

## 根因

### Reader / 阅读历史

Reader的latest-wins串行队列本身保证顺序，但 dev.155 的持久实现仍在 Flutter UI isolate同步执行 sqlite3查询、章节JSON解码与UPSERT；每次完成又通过 `HomeLibrarySession.replaceProgress`发布整页Home投影。正常返回还在路由退出前等待最终写入。因此磁盘/JSON和Home rebuild被错误放进翻页与退出热路径。

### Mihon章节

当前 TachiyomiX/Mihon接口将章节表达为 `SChapter` 列表：1.6组合接口返回 `SMangaUpdate.chapters`，兼容接口为 `getChapterList`/`fetchChapterList`，正文页面为 `getPageList(SChapter)`/`fetchPageList(SChapter)`。`SChapter`不存在“开始/继续阅读action”字段；该文案属于宿主UI。ZIC此前人工构造gallery单章、反射SManga章节属性以及按标题删除“开始阅读”均没有插件接口依据。

### 封面

Mihon封面locator为 `mihon:resource:<opaque>`。漫画源页正确走 `ComicSourceResourceGateway`，但Home/详情曾只把HTTP(S)当远程资源，导致插件URI进入本地文件loader。与此同时Mihon raw `comicId`编码可变SManga快照，而cover cache用raw comicId分namespace；browse/detail字段差异会把同一作品切成多个缓存空间。项目ADR 0074早已记录raw Mihon locator可变，后续cover key规则回退违反了该身份边界。

## 收口

- SQLite progress writer移到独立isolate；Reader只入队，路由返回后再barrier+单次reload。
- 删除Mihon synthetic/title heuristic，只投影真实source chapter API。
- external artwork统一gateway，raw runtime locator与canonical durable artwork identity分离。
