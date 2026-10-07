# ADR 0152：Mihon Source Filter Schema / State 所有权

状态：Accepted
版本：0.31.0-dev.169

## 问题

dev.168 把“是否有筛选”抽成 `supportsSearchFilters=true/false`，并继续把插件筛选压缩为 `Set<String> filterIds`。这与 Mihon ABI 不一致：每个 source 自己通过 `getFilterList()` 返回 Filter schema，默认实现可以为空；插件通常继承 `Filter.Group/Sort/Select/...` 定义自己的 `StatusFilter/OrderByFilter/...`。按 concrete class `simpleName` 判断会漏掉这些子类，flat ID也无法表达 `Text` 与 `Sort.Selection(index, ascending)`。

## 决策

1. 筛选能力事实只有一次：source实际返回的 `FilterList`。空列表表示没有可见筛选；删除独立 `supportsSearchFilters`。
2. Android bridge按 Mihon `Filter.Header/Separator/Select/Text/CheckBox/TriState/Group/Sort` 基类继承关系分类，不能按插件 concrete class名称猜类型。
3. bridge保留 Group树、来源 label/options/default state。未知非官方 Filter基类不得让 Popular/Latest browse失效，但不能伪造业务语义。
4. Catalog/App使用结构化 `SourceSearchFilterNode`；用户状态是相对来源默认值的 `filterState` override：CheckBox=bool，TriState/Select=int，Text=String，Sort=`{index, ascending}`。
5. 空 override保持普通 Latest/Popular路径；只有 query或用户 filter override存在时进入 source search。恢复默认只清除 override，让插件重新拥有默认 Filter状态。
6. filter state属于精确 browse/search cache identity；Presentation不建立第二套筛选缓存。Filter动作仍位于分类栏末尾，但不是 `SourceBrowseSection`。
7. dev.168关于“默认 section由展示排序第一项决定、catalog最近 cache不得恢复导航默认值”的决定继续有效。

## 所有权

- Filter schema/default state：extension source `getFilterList()`。
- Mihon ABI转译：`MihonFilterCodec`。
- 用户临时 override与面板：source-browser Presentation。
- 精确请求/缓存 identity：Catalog/runtime protocol。

## 取代关系

本 ADR取代 ADR 0151中“显式 `supportsSearchFilters` capability”和 flat `filterIds`相关决定；保留 ADR 0151 的默认 Section / cache导航所有权决定，并补充 ADR 0150 的筛选入口位置。
