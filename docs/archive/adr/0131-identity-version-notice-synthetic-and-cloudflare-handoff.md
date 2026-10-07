# ADR 0131：统一身份、同源更新提示与 Cloudflare handoff

**状态：Accepted**

## 决策

1. raw `sourceId + comicId` 是来源定位身份；canonical identity 只比较，不替代 locator。
2. 同源版本关系使用 `sourceId + predecessorComicId + successorComicId`，只能由来源能力或已持久关系产生。
3. 详情只展示 successor 更新提示；Reader 只读已保存关系并按三元 identity 首次提醒。旧版列表和 AppBar 迁移按钮删除。
4. exact chapter identity 才复制阅读状态；sequence-only 只做风险说明。
5. 真实目录存在时 synthetic Mihon chapter 在 manifest、SavedComic、ImportedChapter 与 UI 全部删除。
6. WebView 验证返回后重启目标 source；Mihon 新 runtime 清空进程内 snapshot revision，首个实际 host request 导入最新 same-site snapshot。
7. Dart capability 使用局部 Object 与显式 cast，不依赖跨 getter/async boundary 的自动提升。
