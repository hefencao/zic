# dev.141 漫画源分类、搜索与缓存审计

## 基线

唯一基线：`zic_v0.31.0-dev.140_source-paging-mihon-language-equal-area-preview.zip`。

## 发现

- dev.140 的分类行按 runtime ecosystem 分组，不是来源内部分类。
- Mihon 的真实浏览入口为 Popular/Latest；FilterList 仅属于搜索。
- Venera runtime 可能声明多个 explore loader/category target，旧适配器只选第一项。
- 搜索栏和页码固定占行；页码应随内容出现在底部。
- catalog 已缓存浏览响应，但 UI 请求前清空列表，未利用 stale-while-revalidate。
- 详情预览每行数量由宽度算法隐式决定，没有用户设置。

## 修改

- 新增 source-owned section capability，并贯通 runtime protocol、Mihon 和 Venera。
- 来源类型只以 chip 色彩/图标表达。
- 搜索改为左下浮动展开，历史持久化并可删除/清空。
- pager 放入 CustomScrollView 尾部。
- 缓存页同步投影、后台刷新、稳定字段不变时不更新。
- 预览每行最大项数默认 4，可在阅读设置中调整 1–8。

## 拒绝方案

- 不把 Mihon FilterList 当作分类。
- 不根据插件显示名猜测 Venera/Mihon 源内分类。
- 不在 UI 建立第二套漫画列表缓存。
- 不恢复滚动到底自动拼接为唯一翻页方式。
