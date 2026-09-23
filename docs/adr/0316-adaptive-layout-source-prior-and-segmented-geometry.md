# ADR 0316：自适应布局的来源条漫先验与切片几何

## 状态
Accepted；来源级单向 weight 的第 4–7 条由 ADR 0317 取代，model v6 的切片几何决策继续有效。

## 问题
现有自适应几何继承了早期 VibeVenera 的分段规则：只要页面 `height / width < 1.55`，每个样本都会给分页方向固定增加 1.5 分。因此 1:1、接近 1:1 的来源切片反而成为最强分页证据，而普通 16:9/9:16 页面与长条页之间没有按“离正方形有多远”表达几何信息量。部分条漫来源会把一张长幅正文切成多个近方形 transport page，这会把来源切片方式误认成阅读排版。

来源元数据还能提供诸如“韩国/韓國”等弱线索，但这些词不能等同“韩漫/条漫”。同时，某些来源本身几乎全是条漫，需要用户可调的来源级先验；该先验不能在插件管理、来源管理和 Reader 各保存一份。

## 决策
1. 自适应分类继续由 `reader_runtime.AdaptiveReaderClassifier` 单一拥有。漫画级显式阅读方向仍优先，来源原始 `readingDirection` 仍只是 fallback，不成为自适应证据。
2. model 升为 v6。非封面页面至少两个样本后：
   - 近 1:1 页面只提供很弱或零分页证据；
   - 普通页面在纵向条漫过渡区以下，以 `abs(log2(height / width))` 表示离 1:1 的对称距离，分页证据随距离增加并封顶；
   - 约 1.9–2.2 的纵向比例保留低置信过渡；
   - 更长纵幅逐步形成条漫证据。
3. “韩国/韓國/korea”只加入几何阶段的弱条漫 evidence，不加入直接语言判定，也不产生 terminal metadata profile；明确的 `韩漫/manhwa/webtoon/条漫` 等标签仍沿既有强证据路径。
4. `AppPreferencesController.sourceAdaptiveWebtoonWeights` 是来源条漫权重唯一持久 authority，键为稳定 `sourceId`，值限制在 0–1；0 不落盘且表示完全跟随自动分类。来源管理页只编辑该值。
5. App composition 通过 `ReaderSessionSettings.sourceWebtoonWeight` 把来源权重只读投影给 Reader。Reader 不监听、不写回来源设置，也不建立插件级第二份权重。
6. 非零来源权重进入 adaptive evidence fingerprint；来源权重变化后，旧漫画级 adaptive profile 因 fingerprint 不匹配而自然失效。权重为 0 时保持原 metadata fingerprint，避免无先验场景无意义改变 identity。
7. 高权重可以形成来源级 provisional/terminal vertical prior；较低权重只在后续页面几何与元数据评分中偏置 vertical。运行时几何仍可在非 terminal prior 下继续修正。

## 后果
- 近方形切片不再因为“宽高接近”自动获得高置信分页。
- 1920:1080 与 1080:1920 这类普通页面以对称的比例距离形成分页证据。
- 类似“韩国”这类地域标签只有与几何/来源先验合成后才影响最终方向，不会成为来源名称或漫画名称硬编码。
- 来源级设置对 Mihon/Venera 都按其实际 `sourceId` 生效；不需要为插件生态增加新的 Reader 或 plugin-host authority。
- model v5 的持久 profile 会因版本变化失效并重新分类。
