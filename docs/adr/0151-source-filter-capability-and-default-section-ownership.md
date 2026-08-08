# ADR 0151：Source Filter Capability 与默认 Section 所有权

状态：Accepted
版本：0.31.0-dev.168

## 问题

dev.167 把“筛选”动作放进分类栏，但可见性仍由 `_searchFilters.isNotEmpty` 决定。因此插件虽然具备 `getFilterList()` 能力，只要本次 schema 返回空列表、解析失败或尚未完成，入口就直接消失；能力状态与一次加载结果被错误合并。

同时 section 的 Presentation顺序已经是“最新 → 热门”，但 `_restoreTargetProjection()` 会读取 `peekLatestBrowseProjection()` 并把最近缓存的 `sectionId/query/filterIds` 写回 UI。于是 cache作为数据 owner反向拥有了导航默认值，常见结果是列表第一项为“最新”，首次焦点却仍落在历史缓存的“热门”。

## 决策

1. `FilterableBrowsableComicSource` 显式提供 `supportsSearchFilters`。能力存在与否不能从最后一次 schema列表是否为空推断。
2. Mihon runtime声明 search-filter capability；Venera不声明。Catalog decorator只转发底层 capability，不发明能力。
3. capability存在时分类栏始终显示“筛选”。schema为空时面板显示明确空状态，不能通过隐藏入口表达失败/空结果。
4. browse cache只拥有数据，不拥有 UI导航默认值。source browser删除“最近 projection → section/query/filter state”的反向恢复；只允许当前精确请求缓存直接投影。
5. 首次进入来源的默认 section从**当前 Presentation排序后的第一项**派生。当前排序 owner将 Latest排在 Popular前；未来若支持用户自定义排序，只修改这个排序 owner，默认焦点自动跟随第一项。
6. source切换后回到同一来源时，当前页面生命周期内显式记住的用户选择仍可恢复；这是 Presentation session state，不是 catalog cache默认值。

## 所有权

- filter capability/schema：source/plugin adapter。
- selected filter IDs：source-browser Presentation request state。
- section展示顺序与首次默认项：source-browser Presentation同一排序 owner。
- browse response cache：Catalog，只服务精确请求 identity。

## 取代关系

本 ADR补充 ADR 0150，并取代“filter list非空才显示入口”和“最近 browse projection可恢复 UI默认状态”的 dev.167实现细节。
