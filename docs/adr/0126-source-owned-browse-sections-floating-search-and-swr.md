# ADR 0126：来源自有浏览分类、浮动搜索与后台刷新

**状态：Accepted**

## 问题

dev.140 把原生、Mihon、Venera 运行时类型当作漫画源内容分类，并把搜索栏和页码固定占据页面行。运行时类型不是来源内部的浏览分类；固定栏也压缩了内容空间。漫画源响应虽然进入统一 response cache，Presentation 仍会先清空内容再等待请求，未形成缓存优先、后台刷新。

## 接口审计

- Mihon `Source` 提供 `getPopularManga`、可选 `getLatestUpdates` 和搜索 `getFilterList`。Popular/Latest 是浏览入口；FilterList 是搜索过滤器，不是分类。
- Venera 来源可以包含多个 `explore` loader 和多个 `category.parts` target。旧适配器只使用第一项，丢失了来源声明的分类。
- 现有 `ResourceCacheManager` 已拥有 search-results TTL、weight、LRU 和 in-flight join；不需要页面私有缓存。

## 决策

1. Catalog 增加可选 `SectionedBrowsableComicSource`，section ID 为来源/runtime 生成的不透明稳定值。
2. Mihon 暴露 Popular 和可用时的 Latest；搜索继续使用 FilterList。
3. Venera 枚举全部 explore/category target，并由 opaque section ID 回传真实入口参数。
4. 原生/Mihon/Venera 只在来源 chip 上以颜色和图标区分，不占分类行。
5. 页码控件进入内容滚动尾部；搜索改为来源栏上方左下浮动按钮，点击后横向展开并显示持久化历史。
6. `CachedBrowsableComicSource` 提供同步 peek 和强制 refresh。UI 先投影缓存页，再后台请求；稳定字段无变化时不重建列表。
7. Mihon 已安装/仓库插件的规范化语言筛选继续保留。
8. 详情预览继续使用等目标面积、最大/最小面积比不超过 1.2 和 80% 高度上限；每行最大项数作为 AppPreferences 小型用户设置持久化，默认 4、范围 1–8。

## 所有权

- section 协议与 response cache：catalog/resource_cache。
- Mihon/Venera section 解析：plugin_host / plugin_host_bridge。
- 搜索历史和预览行数：AppPreferences。
- 浮动搜索、底部页码和 cache projection：App Presentation。
- Reader 页面正文缓存、下载与解码不受影响。
