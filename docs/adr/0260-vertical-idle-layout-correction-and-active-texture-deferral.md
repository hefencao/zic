# ADR 0260：纵向 idle geometry 原子校正与 active texture deferral

状态：Accepted（dev.281）

## 背景

13:14 dev.280 真机 Trace 将“松手后抖动”拆成两条不同路径。慢拖在10.432s先以page18、logicalPosition=18.0062进入idle，约6.7ms后在没有反向用户滚动的情况下变成page17、logicalPosition=17.6068；随后Pipeline按page17重排current/retained并重新present已有output。源码对应dev.280的两阶段idle commit：先setState采用新ratio/extents，下一post-frame才用`ScrollController.jumpTo`恢复旧top-pixel anchor。于是至少一个布局/observation窗口会以“新geometry + 旧pixels”解释viewport，而且`jumpTo`本身又制造ScrollNotification。

快速滑动的ballistic段则没有同类反向logicalPosition：20.68→22.83总体单调。但15.502s和15.906s两次`framePipelineTiming`均是不可见`next2`静态startup upload，分别约15.2ms/21.9ms platform upload、14.5ms/17.1ms native Surface blit，第二次channel round-trip约23.7ms。Android blit虽然在texture bridge专用lane执行，仍会产生大块Surface/buffer/memory traffic并与正在动画的viewport竞争。该现象不能继续由anchor逻辑解释。

同时发现dev.279引入的`_SourceWatchBinding.session`已经是可变字段，但constructor仍为`const`，Dart编译会直接失败。此前远程环境没有Dart/Flutter，浅层源码gate未覆盖这一语义错误。

## 决策

1. dev.280的scroll-stable ratio snapshot继续保留：drag/ballistic/settling期间不改变sliver extent。
2. ratio真正idle提交时，不再“先setState换geometry、后post-frame jumpTo”。Reader先用旧geometry捕获top-pixel anchor，再用next geometry计算一个`_pendingVerticalGeometryCorrection` target。
3. 纵向ListView使用Reader私有`_ReaderVerticalScrollPhysics`。新content dimensions建立时，`adjustPositionForNewDimensions`只在`isScrolling=false`且存在pending target时返回该target；Flutter的`ScrollPosition.correctForNewDimensions`因此在layout阶段通过`correctPixels`修正offset并要求viewport重新layout。geometry与pixels在paint前一起收敛，且这笔内部尺寸校正不发送一次假的用户`jumpTo`。
4. pending correction target必须跨该geometry-change frame的所有layout pass存活，frame完成后清除；新ScrollStart立即清除陈旧target。
5. viewport/DPR/stitch/显式navigation继续保留既有anchor/jump合同。本ADR只替换异步ratio idle commit的两阶段恢复。
6. Pipeline保留next2 decode warm，但在`ReadingDirection.vertical`且interaction为dragging/scrolling/settling时，非可见`next2`静态页不创建speculative UploadDemand；current、transition、真实可见静态页和immediate next不受影响。idle后next2 texture warming恢复。
7. `_SourceWatchBinding`移除非法`const`；新增dev.281 gate直接检查“mutable session不能拥有const constructor”。

## 不采用

- 不用timer/grace或更高drag阈值延后commit；idle事实继续由ScrollPosition/interaction决定。
- 不在idle commit继续调用`jumpTo/animateTo`，否则仍会产生可观察scroll activity并驱动Pipeline。
- 不关闭next2 decode、不缩小2/1 decode window，也不降低current/transition/visible upload。
- 不把native texture blit搬回Reader或让Reader直接管理texture slot。

## 验证不变量

- active scroll期间ratio仍不得改变item extent。
- ratio idle commit不得出现“新geometry + 旧pixels”的可观察中间current/page transition。
- page0等viewport前方页面异步变高时，top-pixel视觉锚点和当前可见页面identity必须跨commit连续。
- vertical active scrolling中next2 decode仍存在；不可见next2 static upload暂缓，idle后恢复。
- previous3/next7、decode2/1、holder7/5/3/2、normal5+current reserved1、Venera、generation/partial owner均不变。
