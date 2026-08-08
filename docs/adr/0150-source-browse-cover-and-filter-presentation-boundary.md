# ADR 0150：漫画源 Browse 封面与筛选 Presentation 边界

状态：Accepted
版本：0.31.0-dev.167

## 问题

设备 trace `zic-debug-trace-2026-08-08T09-45-09.jsonl` 显示同一 source 的 browse projection 更新与详情/章节 refresh 交错发生。源码审计发现 `source_browser` 把每次 `_applyBrowsePage()` 的全局 `_contentRevision` 作为全部卡片 `_RemoteImage.reloadToken`；任何分页、SWR 或目录投影变化都会让整页封面重新求值，即使具体漫画的 canonical identity、cover URI 与统一 cache entry 都没有变化。Sliver direct child 又以 mutable raw `comicId` 作为 key，来源详情补全/alias变化也可能把同一 canonical comic 当成新的 Presentation owner。

筛选能力本身已经存在于 `FilterableBrowsableComicSource` 和插件 runtime adapter，但 UI 把 filter chips 藏在展开的浮动搜索面板中，导致来源 section 与搜索过滤的职责和可发现性都不清楚。

## 决策

1. browse projection revision 只属于 catalog metadata，不得成为 artwork revision 或 image reload token。
2. source-card artwork 只在自身 URI/稳定 identity变化，或用户显式来源 artwork refresh revision变化时重新求值。
3. Sliver direct-child Presentation owner 使用 `sourceId + canonical comic identity`；raw locator只用于插件/source调用和交互定位，不拥有 Widget State。
4. 漫画源标准 section 的 Presentation 顺序为“最新 → 热门”；其它 source-owned section保持来源顺序并排在其后。
5. 来源存在 `FilterableBrowsableComicSource` 时，分类栏末尾增加“筛选”动作。Filter仍是 opaque request条件，通过 `selectedFilterIds`进入原 browse/search contract，不创建 `SourceBrowseSection`、第二缓存或第二过滤状态。
6. 浮动搜索只拥有 query 与搜索历史，不再重复承载 filter chips。
7. source-card artwork trace 使用 canonical Presentation identity记录 load/source-ready/first-frame/source-failure/decode-failure，以便后续区分 catalog projection、source/cache 与 Flutter decode层。

## 所有权

- browse/results projection：Catalog + source-browser Presentation。
- filter schema/request：来源 capability / plugin runtime adapter。
- artwork identity/cache：`ComicSourceResourceGateway` / `ResourceCacheManager`。
- source card State identity：canonical comic identity。
- raw comic locator：source/plugin invocation。

## 取代关系

本 ADR 取代旧 dev.141/dev.142 中“filter chips固定在搜索框上方”的 Presentation 选择，以及把 browse content revision用于 source-card artwork reload 的实现约定。既有 catalog cache、统一 artwork owner、source request filter contract继续有效。
