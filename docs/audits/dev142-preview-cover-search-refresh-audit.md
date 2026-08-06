# dev.142 预览、封面、搜索与刷新审计

## 问题

- 固定等面积行居中导致预览图两侧留下未利用宽度。
- cover Future 或 Flutter decoder 一次失败后，Widget 只保留占位图；冷启动重建 ImageStream 后立即恢复。
- 搜索面板展开后返回与垂直滑动仍可能落到页面下层。
- Mihon `getFilterList()` 只在 Android runtime 内创建默认值，没有投影到 Catalog/UI。
- 漫画源页没有用户可见的下拉强制刷新入口。

## 所有权

- 预览装箱：`apps/app/comic_details_extras.dart` Presentation。
- encoded artwork response：`resource_cache` 与 source gateway，未改变。
- Flutter provider/ImageStream 恢复：App artwork presentation。
- 搜索过滤模型：`catalog`；Mihon Filter 反射与赋值：`plugin_host_bridge`。
- catalog SWR/强制刷新：`CachedBrowsableComicSource`；页面只调用 cache projection。

## 实现

- 行缩放限制为最小缩放的 `sqrt(1.2)`，保持面积比不超过 1.2；多项行剩余宽度进入项间 spacing，左右不保留固定黑边。
- `ArtworkRetryController` 管理有界 source Future 重试；`RecoverableArtworkImage` 驱逐局部 provider、重建流并监听 resume。
- 搜索面板使用 back interception、vertical drag 和 scroll notification 收起。
- runtime protocol 新增 `loadSearchFilters` 与 `filterIds`；支持 Mihon CheckBox/TriState/Select/Group。投影初始标签均为未显式选择，Mihon 默认 Filter 状态只在真正执行搜索时保留。
- `RefreshIndicatorTriggerMode.onEdge` + `AlwaysScrollableScrollPhysics` 执行 `forceRefresh`，现有数据不清空。

## 拒绝方案

- 不通过 `BoxFit.cover` 裁掉预览图来假装铺满。
- 不清空全部 image cache 或 response cache 恢复单张封面。
- 不把 Mihon Filter 对象传进 UI。
- 不在页面建立独立搜索结果缓存。
