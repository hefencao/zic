# dev.281 松手抖动、ballistic texture竞争与Dart编译审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.280_vertical-scroll-geometry-snapshot.zip`。
- 真机事实：`zic-debug-trace-2026-08-14T13-14-51.jsonl`。
- 用户现象：慢慢拖动时松手瞬间抖并闪烁不同图片；快速滑动松手后的惯性滑动仍抖。
- 用户补充编译错误：`_SourceWatchBinding` constructor为`const`，但`DownloadSession session`字段不是final。

## 1. 编译错误

`packages/sessions/lib/src/live_coordinator.dart`中`_SourceWatchBinding.session`需要在sealed Reader encoded generation跨transient physical session保留时更新concrete session pointer，因此字段合法地是mutable；constructor却仍残留`const`。这是确定的Dart语义错误，不是设备差异。dev.281直接删除constructor的`const`，并新增source gate禁止该组合再次出现。

当前远程环境没有Dart/Flutter，因此本轮仍不能宣称Dart analyzer/Flutter tests已执行；这次错误也说明静态marker gate不能替代真正编译。

## 2. 慢拖松手：dev.280 idle commit两阶段可见

Trace在10.431633s附近最后一组scrolling observation为page18、logicalPosition=18.0062026；10.432344s进入idle后仍保持相同position。随后没有用户反向scroll event：

- 10.437623s `pageCurrent pageIndex=17`；
- 10.439069s observation变为page17、logicalPosition=17.6068335；
- 10.440830s Pipeline revision44立即按current=17重排；
- 10.465966s一个retained静态output完成`frameUploaded`，随后present。

源码与这一时序一致：dev.280先在idle post-frame执行`setState(_verticalLayoutRatios=pending)`，而旧top-pixel anchor的`jumpTo`位于另一个post-frame callback。新geometry先用旧pixels布局，Reader可先报告另一个stable/current page；下一帧jumpTo再恢复offset，同时制造新的ScrollNotification。用户看到的“松手一下抖并闪不同图片”因此有明确owner，不应再归到下载/decode或旧active-scroll extent mutation。

## 3. 快速松手：ballistic位置单调，竞争来自非可见next2 texture startup

15.05s后快速手势/ballistic中logicalPosition从20.6814连续推进到22.8276，16.8366s才进入idle，没有类似10.432s的反向geometry jump。期间两个显著platform presentation长尾：

- 15.501919s：`role=next2 / traceReason=startup`，platform upload约15,196µs、blit约14,542µs、round-trip约18,001µs；
- 15.906382s：同为`next2 startup`，platform upload约21,867µs、blit约17,088µs、schedule queue约4,612µs、round-trip约23,704µs。

两者都不是current/visible首帧，而是static warm推出来的非可见next2 texture。`TextureBridgePlugin`已有单独`zic-texture-blit-0` executor，因此不能把它误写成“Dart/UI线程执行blit”；但6–8MiB RGBA Surface lock/copy/unlock+schedule仍可与正在做ballistic动画的compositor/buffer路径竞争。Trace证据足以先做最窄策略收口：只暂缓vertical active presentation中的non-visible next2 static upload，decode继续warm。

## 4. dev.281实现边界

### Reader

- dev.280 `_verticalLayoutRatios/_pendingVerticalLayoutRatios`继续冻结active geometry。
- ratio idle commit通过`_preserveVerticalAnchor(... nextRatios: pending)`计算next-geometry restore target，不再排队另一个anchor `jumpTo`。
- `_ReaderVerticalScrollPhysics.adjustPositionForNewDimensions`在content dimensions改变的layout阶段返回该target；ScrollPosition内部通过`correctPixels`和重新layout完成原子校正，避免可观察中间scroll activity。
- correction target保留到该frame结束，允许viewport correction重复layout；新ScrollStart清除陈旧target。

### Pipeline

- `_staticWarmPages`与stable decode window不变。
- vertical dragging/scrolling/settling期间，仅`role==next2 && !visibleStatic`的speculative upload被defer。
- current/transition/visible static/immediate next照常upload；next2 decode照常存在；idle后next2 upload恢复。

## 5. 回归

- Reader widget回归把初始viewport放在page1，active gesture期间让viewport之前的page0 ratio从1扩到3；release后不得短暂报告stableIndex=0，最终current仍为page1。
- Pipeline回归要求vertical scrolling计划中next2 DecodeDemand存在、next2 UploadDemand不存在、next UploadDemand仍存在；同一observation切idle后next2 UploadDemand恢复。
- dev.281 gate检查mutable `_SourceWatchBinding`无const constructor、Reader layout correction owner、Pipeline active next2 deferral以及冻结参数。
