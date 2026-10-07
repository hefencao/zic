# ADR 0265：冻结纵向布局上的实时等比呈现

状态：Superseded

接受版本：dev.286。

## 背景

00:09 dev.285 真机 Trace 中，用户报告“缩放不正常，需要稳定后才正常”。该现象不是 InteractiveViewer 手势本身，也不是 Download/Decode/texture generation 失败，而是 dev.280 之后纵向尺寸 owner 被拆成了两个时间尺度，却仍共享一个“geometry 一定已经精确”的旧假设。

`ReaderRuntimeScreen._reportPageDimensions()`会在首帧得到真实尺寸后异步发布`pageAspectRatios`。dev.280 为避免滑动期间 sliver item extent 改变，要求 dragging/scrolling/settling/scrubbing 期间 `ReaderView` 继续使用冻结的`_verticalLayoutRatios`，新ratio只进入pending并等idle后提交。这个布局约束本身仍正确。

但 stitched continuous Reader 的`LocalImagePlayer`使用`BoxFit.fitWidth`，而`MediaAspectViewport`在该模式下会直接`builder(BoxFit.fill)`，因为历史契约假定`ReaderVerticalGeometry`已经给出精确、等比、物理像素对齐的页面盒。active scroll 时这个假设不再成立：sliver box可能仍是1.5 fallback或旧ratio，而texture/frame已经知道真实宽高，因此媒体被拉伸到旧box，直到idle geometry commit后才恢复正常。

本Trace可对应20个首帧尺寸，其中16个在dragging/scrolling期间到达；这些active-scroll页面真实`height/width`中位约3.20，未知页fallback为1.5，中位相对差超过113%。代表页包括page17 `648×2328`、page9 `608×2280`、page20 `592×2312`。因此不能把问题视为亚像素误差。

## 决策

1. dev.280 的scroll-stable **layout extent**合同继续冻结：一次active vertical scroll中，`ReaderVerticalGeometry`用于prefix、visible coverage、`itemExtentBuilder`的snapshot不得因新ratio改变。
2. 同一`ReaderVerticalGeometry`新增只读`presentationExtentAt(index, latestRatios)`投影。它复用完全相同的ratio/rotation/DPR/上界算法，但只计算某页的最新**visual presentation extent**，不得修改snapshot中的`_extents/_starts`。
3. vertical item始终保留固定layout box；其媒体子树在top-aligned `OverflowBox`中按最新presentation extent获得约束。这样`BoxFit.fill`仍只填充一个等比页面盒，而不是旧fallback box。
4. 当presentation extent大于冻结layout extent时，只在当前page box内临时clip超出的下部；小于layout extent时允许box下部暂时留空。不得为了“看满”而拉伸、裁切横向比例或修改sliver extent。
5. idle后仍由dev.281既有layout-time correction一次性提交pending ratio，使layout extent与presentation extent重新一致；不得恢复active-scroll ratio-driven `jumpTo`或mutable item extent。
6. `MediaAspectViewport`/`NativeTextureViewport`的“精确fitWidth box可用BoxFit.fill”合同继续保留；本ADR只在Reader owner内保证即使layout snapshot暂时陈旧，传给媒体的visual box仍使用最新比例。
7. 不修改Reader 3/7、decode/upload水位、FrameBudget、texture resident reuse、Download/NetLane/Venera或dev.285 promoted retention。

## 拒绝方案

- active scroll中立即更新`itemExtentBuilder`：会恢复dev.280已证实的sliver geometry抖动。
- 等idle后再显示首帧：用隐藏/等待掩盖presentation错误，并显著增加可见延迟。
- 全局把`MediaAspectViewport(fitWidth)`改回第二层FittedBox：会重新引入stitched边界双重比例计算与亚像素接缝风险，而且把Reader geometry过渡态泄漏给通用媒体组件。
- 继续使用stale box但加scale动画/timer：无法保证真实比例，也建立新的时间型presentation owner。

## 验证

- active scroll期间ratio更新后，`reader-vertical-page:*`的layout height必须保持不变。
- 同一帧后`reader-vertical-presentation:*`必须已经按最新ratio获得新的等比height，而不是等到idle。
- idle后layout height再收敛到该presentation height，并保持dev.281 top-pixel layout correction语义。
- `MediaAspectViewport(fitWidth)`仍可使用`BoxFit.fill`，因为Reader给它的visual child box在过渡期间也保持等比。

## Superseded by dev.287

00:35 dev.286真机仍报告“稳定后才正常”。dev.286只能在冻结sliver extent内把拉伸改成裁切/留白；当真实ratio直到页面已进入viewport后才到达时，不可能同时保证全宽、完整内容、比例正确和scroll-stable extent。dev.287把尺寸事实前移到decode-time并只提前准备真实viewport尾部之后的geometry；production不再使用`presentationExtentAt`/OverflowBox过渡workaround。
