# dev.283 vertical target directionality audit

## 设备事实

输入：`zic-debug-trace-2026-08-14T14-52-15.jsonl`。

页面序列先从18前进至27，再反向回到19，随后再次22→20，提供了同一Reader会话内的next/previous对照。dev.282 resident presentation在反向段已多次命中`platformResidentReuse=true`，对应platform blit/schedule/channel round-trip均为0；scroll logicalPosition在反向段总体单调，没有dev.280 slow-release那类无输入反向geometry jump。

方向性异常集中在target：过滤`abs(velocity)>0.01`且`visibleIndexes`只有current的observation后，previous/index下降有22次仍报告higher-index hidden target；next/index上升同类为10次。例如current26、visible=[26]、velocity=-1.53仍target27；current24、visible=[24]、velocity=-1.20仍target25。

## 源码闭包

`ReaderVerticalGeometry.positionAt()`以viewport center定位页面，并返回`logicalPosition = index + page-local fraction`。`_emitFromVerticalMetrics()`已经基于真实`visibleCoverages`计算target，但当没有第二可见页时传入null。通用`_emitObservation()`随后又执行PageView专用floor/ceil fallback，于是vertical page-local fraction被误读成page-to-page transition fraction。

dev.283仅在vertical调用处关闭该fallback。真实visible outgoing/incoming target仍由`_verticalTargetCoverage()`提供；horizontal/PageView路径不变。

## 回滚审查

- dev.280/281 geometry：本Trace无对应offset/current回跳，不回滚。
- dev.282 resident reuse：本Trace存在大量零copy命中，不回滚。
- dev.281 hidden next2 upload deferral：本轮不扩大结论。它可能影响资源时序，但当前方向性target错误已足以单独解释previous侧额外transition churn；在修复target后再由真机比较决定是否需要单独回滚该优化。

## 下一份Trace判据

previous/index下降时，`visibleIndexes=[current]`不得再伴随`target=current+1`。若仍抖，先比较pageHost mount/rebuild、真实visible transition、Flutter frame timing；不要先回到anchor、texture duplicate-copy或扩大window。
