# ADR 0259：纵向滚动期间冻结布局几何快照

状态：Accepted（dev.280）

## 背景

12:24 dev.279 真机 Trace 中，dev.279 两条生命周期修复已经出现预期闭环：本地 Reader re-entry 共记录13次 `sealed-source-generation-preserved`，均为 `invalidatedUploads=0 / invalidatedDecodes=0`；冷启动网络 Reader 也实际出现多页 `local-hydration-ready committedLength>0`，current page234 约328ms得到首帧，跳到page139后从262,800-byte durable prefix起步并约125ms得到首帧。因此本轮不再继续修改generation或partial owner。

同一 Trace 的纵向滑动仍有用户可见画面抖动。Reader observation 的 logicalPosition 在连续drag/ballistic段内总体单调，没有与抖动对应的反向page jump，也没有证据表明dev.207已删除的ratio-driven主动anchor `jumpTo`重新出现。源码审计发现，`ReaderRuntimeScreen._reportPageDimensions()`仍会在异步尺寸到达后发布新的`pageAspectRatios` map；`ReaderView`虽然不再因该map变化主动保存/恢复anchor，但`ReaderVerticalGeometry`和`ListView.itemExtentBuilder`会立即采用新ratio。这样用户手指仍在拖动或惯性滚动时，viewport前方页面的sliver extent可以改变，Flutter布局层可产生自身scroll correction或内容起点位移，表现为画面抖动。

## 决策

1. `ReaderView`继续是纵向presentation geometry唯一owner。运行时测得的ratio仍由`ReaderRuntimeScreen`发布，但不直接等同于当前scroll gesture使用的布局几何。
2. 纵向Reader维护一个`_verticalLayoutRatios` immutable snapshot。一次drag、ballistic scroll、settling或page scrub期间，`ReaderVerticalGeometry`、`itemExtentBuilder`、可见覆盖率与position计算全部使用同一个snapshot。
3. 滚动期间到达的新`pageAspectRatios`只覆盖`_pendingVerticalLayoutRatios`，不修改当前sliver extent；多次更新latest-wins，不建立第二份媒体尺寸owner。
4. 真正进入idle后，Reader一次性提交最新pending ratio。提交前使用旧geometry保存top-pixel anchor，提交新geometry后只恢复这一笔真实extent变化；若用户在恢复前再次开始滚动，既有scroll notification会取消pending anchor，禁止post-frame jump与新gesture竞争。
5. viewport、DPR、vertical stitch和显式页面导航继续沿用既有anchor/定位合同；本轮只约束异步media-ratio造成的item extent mutation。
6. 不用timer、drag阈值、额外ScrollController、页面重叠或固定高度掩盖问题，也不冻结decode/upload/texture或媒体尺寸生产。

## 验证不变量

- active vertical scroll期间ratio map变化不得改变当前page item extent。
- ScrollEnd/真正idle后必须采用最新ratio，而不是永久冻结fallback geometry。
- ratio提交后的top-pixel视觉位置应保持连续；不得恢复dev.207已删除的“每次ratio变化都立即post-frame jumpTo”。
- previous3/next7、decode/upload水位、NetLane、FrameBudget、Venera、partial与generation生命周期全部不变。
