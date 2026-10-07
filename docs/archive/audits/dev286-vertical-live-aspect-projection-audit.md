# dev.286 纵向实时比例呈现审计

## 设备事实

输入：`zic-debug-trace-2026-08-15T00-09-17.jsonl`（dev.285）。用户现象：“缩放不正常，需要稳定后才正常”。

Trace没有专门的zoom gesture事件，但frame/Reader observation足以定位一个与“稳定后恢复”严格一致的presentation竞态：

- 可对应到页面的20个首帧尺寸中，16个在`dragging/scrolling`时才到达真实尺寸；只有初始page13~16的4个在idle阶段完成。
- active-scroll 16页的真实`height/width`中位约3.20，范围约1.99~3.91；未知纵向page在`ReaderVerticalGeometry`中fallback为1.5，中位相对偏差超过113%。
- 代表样本：page17 `648×2328` ratio≈3.59，page9 `608×2280`≈3.75，page20 `592×2312`≈3.91。
- dev.280在这些尺寸到达时会正确把最新`pageAspectRatios`留在pending，直到scroll idle才改变sliver extent。

## 源码归因

`ReaderRuntimeScreen._reportPageDimensions`发布真实ratio后，`ReaderView.didUpdateWidget`在active scroll只更新`_pendingVerticalLayoutRatios`；`_verticalLayoutRatios`和`ReaderVerticalGeometry`继续保持旧snapshot。这是dev.280为避免scroll correction抖动建立的正确layout invariant。

冲突来自stitched continuous presentation：`ReaderRuntimeScreen`给页面`mediaFit=BoxFit.fitWidth`，`MediaAspectViewport`又因为“ReaderVerticalGeometry拥有精确页面box”直接对真实frame使用`BoxFit.fill`。当snapshot仍是fallback/旧ratio时，真实frame会被强制填满错误height，视觉上就是比例/缩放异常；idle后pending ratio提交，box突然变成真实比例，于是用户观察为“稳定后才正常”。

## dev.286 收口

- 不回滚dev.280 geometry freeze；sliver layout仍使用scroll-stable snapshot。
- `ReaderVerticalGeometry.presentationExtentAt()`用最新ratio计算单页visual extent，不写入snapshot prefix/extents。
- vertical item的重型page shell保持同一element位置，只改变稳定存在的presentation wrapper尺寸；最新visual extent在top-aligned OverflowBox中约束媒体，parent仍保持旧sliver height。
- mismatch期间临时clip vertical overflow，禁止把真实frame拉伸到旧box；idle commit后layout/presentation重新一致。
- 不修改通用`MediaAspectViewport` fitWidth合同，避免恢复stitched双重FittedBox/亚像素接缝。

## 附带复核

新Trace中的dev.285 promoted retirement事件均带`reason=hot-promoted-retention-pressure`；普通“idle即全退”签名没有恢复。当前缩放问题不要求回滚downloads retention。

## 下一份Trace/真机判据

持续滑动到尚未完成尺寸探测的新页面时，首帧一旦可见就必须保持真实宽高比；不得再出现先被纵向拉长/压扁、停稳后才恢复的阶段。与此同时页面滚动位置仍应保持dev.280/281的scroll-stable geometry：不能为了比例正确重新引入active-scroll item extent跳变。
