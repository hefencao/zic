# dev.169 Mihon Filter 接口根因审计

## 现象

Mihon 中不同插件展示完全不同筛选：例如某来源可有类型、排序、搜索范围，另一来源只有连载状态；ZIC dev.168却可能没有筛选或只显示少量 toggle。

## 根因

1. Mihon API由 source的 `getFilterList()`提供 schema，不存在“所有 Mihon source都有筛选”的统一业务 capability；默认 FilterList可以为空。
2. dev.168 Android bridge读取 `filter.javaClass.simpleName`并搜索 `group/checkBox/triState/select`字符串。插件自定义 `StatusFilter : Filter.Group`、`OrderByFilter : Filter.Sort`时 simpleName不含基类名，因此合法筛选会被静默丢弃。
3. mapper只支持 Group/CheckBox/TriState/Select，且拍平 Group；官方 Text、Sort、Header、Separator丢失。
4. `Set<String> filterIds`只能表达 toggle/选项，无法无损表达 Text字符串和 Sort的 index + ascending。

## 收口

- 删除 `supportsSearchFilters`，恢复“实际 schema非空才显示筛选”。
- 新增纯 Kotlin `MihonFilterCodec`，由 source classloader加载官方 Filter基类并以 `isInstance`识别自定义子类。
- 完整转译 8 类 Filter并保留 Group层次；用户 override使用类型化 `filterState`。
- App根据 normalized schema渲染通用控件，不硬编码插件业务字段。
- 继续保留 dev.168 的默认 Section 规则：当前排序第一项即首次默认项。
