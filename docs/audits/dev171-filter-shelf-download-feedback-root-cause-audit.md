# dev.171 根因审计：筛选视图、书架投影与下载完成反馈

## 输入证据

输入设备 trace：`zic-debug-trace-2026-08-08T12-41-26.jsonl`。

### Trace结论

- 本轮 trace没有记录 `taskFailed`；WNACG source card在设备上持续出现 cover source-ready/first-frame，Reader也正常产生网络 downloadStarted，说明 dev.170 cleartext/hot-loop故障没有在本样本重现。
- WNACG filter请求仍以 `sectionId=latest, filterCount=1`记录；不存在独立 filter-view状态。这与UI在应用筛选后仍把 Latest/Popular当作选中分类一致。
- trace能证明 artifact/cache resident页面可被Reader直接复用，但现有 trace没有“Home下载勾来源”事件；该错误由源码审计直接定位：`_downloadProgressForComic`只要看到任意 completed chapter snapshot就构造 persistent `offline` watermark。

## 根因 1：filter state承担了两种语义

旧逻辑只有 `_filterState`。UI的 Filter是 `ActionChip`，没有 selected/focus状态；filtered route又仅在 `_filterState.isNotEmpty` 时发生。因此：

- 插件默认 FilterList（empty override）无法执行；
- 应用筛选后仍由 Latest/Popular chip承担焦点；
- cached browse无法区分 ordinary section + empty state 与 default-filter + empty state；
- Android Mihon driver还用 `filterState.isEmpty()`选择 Popular/Latest，进一步丢失默认筛选。

修复为独立 `filterViewActive/useFilters` mode，并贯穿 Presentation、Catalog key、runtime payload、Mihon driver。

## 根因 2：source card缺少 library projection

source browser只有 source/catalog数据，没有 Home/library preference输入，因此无法知道 canonical comic是否已经入书架。修复不是在 source page增加书架store，而是由 DemoHome以现有 canonical preference合并逻辑投影 `inShelf`。

## 根因 3：完成勾错误绑定 durable cache

旧 `_downloadProgressForComic`把任何 `ChapterDownloadSnapshot.isComplete`聚合成 `ComicDownloadProgress.offline`。这把“该章节已有完整 artifact”和“用户刚发出的下载命令已经完成”混为一件事，多章节漫画只离线一章也会永久出现完成勾。

修复后 durable snapshots只继续服务 active progress/下载管理；完成勾只由显式单章命令返回或显式 whole-comic queue complete生成，并在进入详情时消费。

## 未改变

- Reader/Pipeline 7/3、7/5/3/2、decode 2/1等策略不变。
- Mihon Filter schema仍完全来源于插件 `getFilterList()`，不硬编码站点业务筛选。
- source browser不拥有 shelf membership；Home不拥有下载/artifact事实。
- WNACG/network policy本轮没有继续修改。
