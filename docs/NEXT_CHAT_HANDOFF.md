# dev.90 handoff

唯一后续基线：`zic_v0.31.0-dev.90_mihon-runtime-canonical-identity.zip`。不得混入 dev.89 或更早候选。

## 当前边界

- `network_bridge/android/src/runtime/kotlin` 同时是 network AAR 与 Mihon ABI asset 的共享 Android runtime source set；`NetworkBrowserSnapshotStore` 不得移回仅 main 可见的位置或复制。
- raw Mihon/Venera `comicId` 是加载 locator；canonical identity 只比较同源别名，不能持久化替换 locator。
- `catalog` 拥有 alias collapse/优选；App composition 拥有路由、preference 合并和目录回归检查；详情 Presentation只消费 identity matcher。
- 已观察到真实多章节后，任何 alias 的空/synthetic/单章节目录都必须拒绝。

## 设备复验

1. 打开此前重复显示的同一 Mihon 漫画，确认更新区和书架只剩一个卡片。
2. 从来源页分别点击可能产生旧/新 SManga 模型的入口，均应进入完整章节详情。
3. 连续下拉刷新和 WebView 验证后，不能出现绿勾+单章节。
4. 若仍异常，导出 Trace，保留 `comic-identity-alias-resolved`、`chapter-catalog-refresh-result`、`chapter-catalog-regression-rejected`。

## 未改变

Reader/Pipeline 7/3、2/1、current/transition、5/3/2、256 KiB chunk、GET/HEAD 零 body、DownloadSession/artifact 所有权均未改变。
