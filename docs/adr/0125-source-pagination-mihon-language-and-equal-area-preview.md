# ADR 0125：漫画源显式分页、Mihon 语言分类与等面积预览

**状态：Superseded**

由 ADR 0126 取代。Mihon 插件语言筛选与等面积预览约束在 ADR 0126 中继续保留；按运行时类型占用分类行的决策被废止。

## 问题

漫画源页只提供来源横向列表，并依赖滚动到底隐式追加；Mihon 插件已安装和仓库列表未按语言分类。详情预览的折叠态使用固定 `124×190` 横向列表，展开态使用三槽位分页，两套布局会跳变，且混合横纵图的显示面积差异过大。

## 决策

1. 漫画源页按原生、Mihon、Venera 分类；当前来源的 catalog 以 24 项固定页显式请求，并提供上一页/下一页。
2. 切换来源、分类、搜索 query revision 时回到第一页；不再以滚动到底作为翻页入口。
3. Mihon 已安装和仓库插件按规范化语言分类。插件声明优先，缺失时从 source metadata 推导；多语言和未知语言独立归类。
4. 详情预览按原始顺序贪心逐行装箱。所有 tile 使用同一目标面积，根据自身宽高比计算宽高，因此面积比为 1.0，不超过 1.2。
5. 折叠与展开复用同一布局；折叠只显示第一行并使用其实际高度。展开继续加载全部预览分页，以 `PageView` 呈现后续行，图片区域不超过屏幕高度 80%。
6. 展开控制居中，仅显示上下箭头。

## 所有权

- catalog 分类、分页和 page offset：`apps/app/source_browser.dart` 只做 presentation/session state，来源数据仍由 `BrowsableComicSource.browse` 提供。
- Mihon 语言归一化：`external_plugin_repository_model.dart`；插件页面只投影筛选结果。
- 预览行/页规划：详情 presentation；encoded bytes 仍由统一 artwork loader/cache 管理。

## 否决方案

- 不为每个来源建立独立无限滚动缓存。
- 不从 Mihon 插件名称猜测语言。
- 不保留折叠/展开两套预览尺寸算法。
- 不通过强制裁切使缩略图看似等大。
