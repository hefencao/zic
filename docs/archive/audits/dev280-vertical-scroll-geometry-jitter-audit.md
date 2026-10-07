# dev.280 纵向滑动画面抖动根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.279_reentry-partial-lifecycle.zip`。
- 真机事实：`zic-debug-trace-2026-08-14T12-24-40.jsonl`。
- 用户现象：纵排模式下滑动时画面抖动，怀疑重新anchor。

## dev.279 收口复核

本轮先复核上一阶段是否仍有残留问题，再进入纵向Reader：

- 本地re-entry出现13次`reader-source-watch-rebind / sealed-source-generation-preserved`，全部`invalidatedUploads=0 / invalidatedDecodes=0`，未再出现dev.278样本中的same-exact批量`physical-generation-changed`。
- 冷启动网络Reader已经出现18次`local-hydration-ready`，代表prefix包括262,800、493,480、1,212,416、1,623,520、5,094,940、5,947,392 bytes等，不再是上一轮“全部committedLength=0”。
- current page234 mount后约327,923µs首帧；scrub到page139后该页以262,800-byte local prefix进入physical owner，约124,930µs首帧。
- lifecycle阶段还实际记录多份`reason=app-lifecycle-checkpoint / action=stored`，说明checkpoint不是仅存在于源码合同。

因此当前样本没有要求继续修改dev.279 generation/partial owner；该阶段可暂时收口。best-effort lifecycle barrier对“OS不给任何callback/I/O时间直接瞬杀”的限制仍保持，不扩大承诺。

## 纵向抖动证据

Trace中连续纵向drag/scroll段的`logicalPosition`总体平滑、单调，例如139→138、138→137、137→138→139→140→141→142等连续运动，没有与每次视觉抖动对应的显式反向page navigation。源码中dev.207也已删除`pageAspectRatios`变化直接触发`_preserveVerticalAnchor`的路径。

真正剩余的几何竞态位于：

`media header/output dimensions -> ReaderRuntimeScreen._reportPageDimensions -> ValueNotifier<pageAspectRatios> -> ReaderView rebuild -> ReaderVerticalGeometry -> ListView.itemExtentBuilder`

`_reportPageDimensions`在源metadata缺失或runtime比例与metadata差异足够大时异步发布新ratio。ReaderView虽然不主动jump，但build会立即用新map重算整章extent/prefix starts。用户仍在拖动或ballistic scroll时，viewport前方item高度因此改变；Flutter sliver为维持布局可修正scroll offset，或者同一raw pixels对应的内容起点发生变化。视觉上像“重新anchor”，但owner不是ZIC显式anchor restore，而是**active scroll期间mutable item extent**。

## dev.280 修改

- ReaderView新增scroll-stable `_verticalLayoutRatios` snapshot。
- dragging/scrolling/settling/scrubbing或ScrollPosition仍在scrolling时，incoming ratios latest-wins暂存在`_pendingVerticalLayoutRatios`。
- `_verticalGeometry()`默认只读取snapshot，因此同一次scroll中的itemExtentBuilder、positionAt和visibleCoverages共享不变geometry。
- ScrollEnd进入idle后post-frame一次性提交pending ratios；提交前保存旧top-pixel anchor，下一帧使用新geometry恢复。新scroll会清掉pending anchor，避免恢复动作与手势竞争。
- viewport/DPR/stitch/显式navigation既有语义不变。

## 回归重点

新增Reader widget contract要求：active vertical gesture期间发布一个会显著改变page0高度的ratio，页面height必须保持旧值；gesture结束并settle后才采用新height。现有“measured geometry eventually updates”和“ratio update不重建page content”合同继续保留。

当前远程环境若无Flutter/Dart SDK，不得把该widget test声明为已执行通过；静态owner/history gate只能证明实现边界存在。
