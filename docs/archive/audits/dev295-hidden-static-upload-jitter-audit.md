# dev.295 hidden static texture upload 抖动审计

## 输入
用户在dev.294后提供`zic-debug-trace-2026-08-15T08-15-40.jsonl`，当前问题仍仅为固定区域/滑动抖动；dev.293已解决的缩放问题不重新打开。

## actual-layout 复核
Trace包含333条`pageLayoutSnapshot`。实际`renderHeight`与`ReaderVerticalGeometry.expectedExtent`逐条一致，`extentDeltaPx`为0；采样transform的scale/shear分量保持identity。相邻可见page在同一采样时点的placement residual同步，不支持“单个Sliver child box自己上下跳”的假设。

dev.294的`layoutResidualPx = globalTop + capturedPixels - expectedStart`存在时序瑕疵：RenderBox在post-frame读取，而`capturedPixels`来自安排post-frame callback之前的ScrollMetrics。active scroll期间两者天然不同步。本轮改成callback内读取live `ScrollPosition.pixels`，并额外保留`scheduledScrollPixels`，因此后续residual才可作为同一时点layout事实。

## presentation竞争证据
- hidden page11：active vertical时role为`next`且不在真实visible set，仍产生static UploadDemand；Android present约24.416ms，platform blit约17.799ms。
- hidden page10：同类hidden `next` present约14.809ms，platform blit约10.657ms。
- 这些工作发生在viewport仍由其他page占用的active scroll窗口，说明dev.281只按`role == next2` defer留下了角色漏洞。

## 源码根因
`HeuristicPolicy`此前用`deferVerticalNext2Upload`只识别hidden `PageRole.next2`。`staticWarm`本身覆盖稳定decode role，因此hidden immediate `next`依旧可以进入UploadDemand并触发Android RGBA→SurfaceProducer presentation。该问题无需缩小decode 2/1：decode warm与texture upload admission本来就是两个owner。

## dev.295 修复
- 将角色特例改为`deferHiddenVerticalStaticUpload`：vertical active + staticWarm + 非primary current/transition + 非真实visible时统一defer。
- current/transition始终保持primary upload；真实visible static仍允许upload。
- hidden next/next2/previous仍可decode warm，idle后恢复static warm upload。
- 修复`pageLayoutSnapshot` residual的live-scroll时序，不改变任何layout行为。

## 下一次设备判据
同一抖动区域慢拖、fling、ballistic、settling：active窗口中hidden speculative static不应再出现新的texture upload/present；若抖动仍在，直接比较current/transition output identity、presentation path与SurfaceProducer/compositor timing，不重新调整Sliver extent、FittedBox、source metadata、download或retention。
