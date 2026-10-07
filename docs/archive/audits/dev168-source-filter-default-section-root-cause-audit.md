# dev.168 Source Filter / 默认 Section 根因审计

## 用户现象

- dev.167 实机没有看到“筛选”栏目。
- 虽然“最新”已经排在“热门”之前，首次打开焦点仍落在热门。

## 根因

1. “筛选”ActionChip 只在 `_searchFilters.isNotEmpty` 时创建；一次 schema load结果错误地充当 capability。
2. `_restoreTargetProjection()` 在精确 cache miss 时调用 `peekLatestBrowseProjection()`，并把 cache中的 `sectionId/query/filterIds` 写入 Presentation state。最近 browse若为 Popular，就覆盖了“第一栏目”默认规则。
3. `_loadSource()` 的 fallback使用来源原始 `sections.first`，而 UI又单独调用 `_displaySections()`排序；默认选择与展示顺序存在两个 owner。

## 收口

- `FilterableBrowsableComicSource.supportsSearchFilters` 显式声明能力；Mihon=true，Venera=false，Cached decorator透明转发。
- 分类栏以 capability决定是否保留“筛选”，不再以 schema非空决定。
- schema为空时筛选 sheet显示明确空状态。
- `_orderedBrowseSections()` 同时承担展示顺序与默认项派生；首次无显式用户选择时选 `orderedSections.first`。
- source browser不再消费 `peekLatestBrowseProjection()`恢复 UI。精确请求缓存仍可直接复用。

## 非目标

- 不改变 plugin `filterIds` 编码。
- 不把筛选伪装为 `SourceBrowseSection`。
- 不删除 source切换期间的页面内显式选择记忆。
- 不修改 artwork/cache/Pipeline/Reader。
