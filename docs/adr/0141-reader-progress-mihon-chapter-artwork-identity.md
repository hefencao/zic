# ADR 0141：Reader进度热路径、Mihon章节接口与Artwork身份收口

**状态：Accepted**

## 背景

dev.155之后出现三个看似分散的现象：Reader翻页/退出和整App卡顿；Mihon目录失败时出现无效单章节并可能与第一章重复；同一漫画在漫画源、详情和首页历史之间封面表现不一致。审计确认三者都来自所有权/身份边界回退，而不是缺少更多重试。

## 决策

1. `ReadingProgress` 的 latest-wins顺序仍由 Reader保证，但 SQLite实现使用独立 isolate/WAL connection执行同步查询、章节校验和写入。Reader回调只入队；不得逐页发布 `HomeLibrarySession`。Reader route返回后 composition等待 progress barrier，再一次性 reload历史。
2. Mihon chapter catalog只接受来源API：TachiyomiX 1.6 `SMangaUpdate.chapters`，或兼容 `getChapterList`/`fetchChapterList`。不得从 manga URL构造 `SChapter`，不得按“开始阅读/正文/Start Reading”等标题推断宿主action并增删章节。失败保持失败，成功空目录保持空目录。
3. raw external `comicId` 是 runtime locator。Mihon locator可包含可变 SManga快照，因此不得作为 durable artwork namespace。来源 canonical comic identity用于同源 durable comic/artwork alias；raw locator继续用于插件调用、章节归属和 Reader identity。
4. Home、漫画源、详情、迁移的所有非本地 artwork locator统一进入 `ComicSourceResourceGateway`。gateway先以 canonical artwork identity探测 memory/durable response cache，miss后才解析 source。`mihon:resource:` 等插件URI不得回落到本地文件读取。
5. artwork cache invalidation必须使用与加载相同的 canonical namespace。

## 取代

本 ADR取代 ADR 0043、0046、0069、0132 中关于 Mihon synthetic/gallery单章节和按“开始阅读”标题去重的生产规则；这些文档只保留历史。它同时纠正后续“foreground cover使用 raw library identity”的缓存假设，并恢复 ADR 0074 已确立的 raw runtime locator / canonical same-source identity分离。Reader/Pipeline的资源和调度所有权不变。
