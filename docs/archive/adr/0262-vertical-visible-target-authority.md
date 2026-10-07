# ADR 0262：纵向 target 只能来自真实可见 coverage

状态：Accepted

接受版本：dev.283。

## 背景

14:52 dev.282 真机 Trace 显示明显方向不对称：next/index 上升相对平滑，previous/index 下降抖动严重。dev.280/281 的 geometry 路径没有重新出现 idle current/logicalPosition 回跳，dev.282 的 retained texture 复用也已大量记录 `platformResidentReuse=true` 且 platform blit/schedule/round-trip 为 0，因此继续向 anchor 或 texture 叠补丁缺乏证据。

Reader 源码中，纵排 `_emitFromVerticalMetrics()` 会先由真实 `visibleCoverages` 计算 `_verticalTargetCoverage()`。当只有 current 可见时该函数正确返回 null；但通用 `_emitObservation()` 随后把 null 解释为“没有 target override”，再次按 `logicalPosition > stableIndex ? ceil() : floor()` 推导 target。这个 fallback 是横向 PageView 的页间 fractional-position 语义；纵向 `ReaderVerticalGeometry.positionAt()` 的 logicalPosition 实际是 `index + 当前页内部 fraction`，几乎天然大于 index，因此 hidden target 系统性偏向 higher index。

14:52 Trace 中，previous 方向有 22 次 `velocity<0 + visibleIndexes=[current] + targetIndex=current+1`，next 方向对应样本为 10 次。previous 时该错误 target 是刚离开的页，会被升级为 transition priority，直到真实 incoming previous 进入 viewport 后 target 才再翻转，制造不必要的 role/demand/presentation churn。

## 决策

1. 横向/PageView 继续允许 `_emitObservation()` 根据 page interpolation 推导 target。
2. 纵向 observation 显式禁止 logical-position target fallback；其 target 只能来自 `_verticalTargetCoverage()` 的真实 viewport coverage。
3. 只有 current 可见时，纵向 `targetCoverage` 必须为 null。
4. 若 outgoing page 仍真实可见，可继续作为 transition 直到离开 viewport；若 travel-direction incoming page 真实进入 viewport，则按既有规则成为 transition。禁止为了“方向正确”提前虚构尚未可见的 page。
5. 不改变 previous3/next7、decode2/1、holder7/5/3/2、NetLane、Venera、texture resident reuse 或 vertical geometry snapshot/correction。

## 驳回方案

- 不回滚 dev.280/281 geometry：当前 Trace 没有恢复其已修复的 idle 错页证据。
- 不回滚 dev.282 resident reuse：零 copy telemetry 已真实命中，且该机制本身不解释 target 的方向不对称。
- 不通过扩大 previous window、提高 previous priority 或增加 keepAlive/cacheExtent 掩盖错误 target；先恢复 observation 语义。

## 验证

- previous/index 下降且 `visibleIndexes` 只有 current 时，`targetIndex` 必须为 null。
- 真实 outgoing/incoming 邻页仍在 viewport 时，transition coverage 继续存在。
- 横向 PageView midpoint/outgoing transition 行为保持原有测试合同。
