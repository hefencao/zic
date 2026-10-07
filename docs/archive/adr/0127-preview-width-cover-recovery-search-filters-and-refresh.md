# ADR 0127：预览宽度利用、封面恢复、来源过滤与强制刷新

**状态：Accepted**

## 背景

dev.141 的等面积预览以固定目标面积居中，竖屏完整行仍可能在左右留下未利用空间。封面 encoded bytes 已可快速命中缓存，但 Flutter ImageStream 或一次传输 Future 失败后，部分卡片会永久停留在占位图，直到进程重启。浮动搜索未完整接管返回/滚动手势，也未暴露 Mihon `getFilterList()`；漫画源页缺少明确的下拉强制刷新。

## 决策

1. 预览先按统一目标面积逐行装箱，再按行受限放大；最大行缩放与最小行缩放之比不超过 `sqrt(1.2)`。完整行把剩余宽度分配到项间距，优先贴近左右边缘，面积比合同保持不变。
2. `RecoverableArtworkImage` 只驱逐失败的 ImageProvider 并重建 ImageStream。首页、漫画源卡片和详情封面各自对 encoded-source Future 使用有界短延迟重试，并在 App resumed 时恢复失败项。
3. 不清空 `ResourceCacheManager`，不建立第二套封面缓存；`sourceVerificationRequired` 不自动循环，继续显示 WebView 恢复入口。
4. 浮动搜索展开时由本地面板优先消费返回和垂直拖动/滚动手势，手势发生后释放焦点并收起为浮动按钮。
5. Catalog 增加可选 `FilterableBrowsableComicSource`。Mihon adapter 把 `getFilterList()` 中 CheckBox、TriState、Select 和 Group 子项投影成 opaque filter ID；UI 只切换和回传 ID。插件默认 Filter 状态由 Mihon runtime 自己保留，不自动视为用户已选择的 ZIC 标签，避免空查询误走 Search 而绕过 Popular/Latest。
6. 漫画源 `RefreshIndicator` 达到边缘下拉阈值后调用 `forceRefresh`。已有内容继续显示，新的稳定字段不同后才替换；刷新同时提高 artwork retry revision。

## 后果

- 预览布局更充分利用竖屏宽度，但极稀疏末行仍受面积比 1.2 限制，不会无限放大单图。
- 封面可在不重启 App 的情况下恢复瞬时传输或解码失败。
- Mihon 自定义过滤器不跨越 runtime/catalog 所有权边界。
- 下拉刷新不会先清空 catalog 页面或造成无意义封面重载。
