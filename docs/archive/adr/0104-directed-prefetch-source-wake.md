# ADR 0104：定向预加载 Source Wake

**状态：Provisional**

## 背景

dev.119 设备 Trace 证明，静态 output 驻留已经生效，但正常 7/3 预加载仍未完成。多个页面在进入视口前已经拥有 download/decode/upload demand，正文也已 `sourceReady`，却长期停留在 `waitingSource`：

- page 7：source ready 到权威分类约 4.08 秒；
- page 11、12：约 22.97 秒；
- page 13、14：约 25.2 秒；
- page 5、6：约 39–43 秒。

这些页面都在成为 transition/current 或发生后续 observation 后才执行第一帧。

源码审查确认，source listener 虽记录了未消费 revision，但 `_runDecode` 仍调用全局 `_nextDecodeRefill()`。若全局策略选择其他页面，本次 source wake 被重定向；原页面只能等待另一个无关事件再次提交任务。queued task 还可能使用提交时计算的旧 `sourceWake` 布尔值。

## 决策

- source revision 是否未消费，在 decode task **实际开始时**重新计算，不信任提交时快照。
- 存在未消费 source revision 时，仍使用同一个 `StagedDecodeRefillPolicy`，但 eligibility 只允许该 DecodeId；source event 因此产生定向 staged refill。
- 普通 ticker、upload follow 和 refill 链仍使用全局 c/n/m/p 仲裁。
- 定向 refill 为空时，只有在页面已经 terminal、达到目标或无需继续 fill 的情况下才消费该 revision。
- `decodeRefill` 记录 `sourceWake`、`sourceRevision` 与 `consumedSourceRevision`。

## 取舍

定向 source wake 会让一个较低优先级预加载页在其正文真正到达后获得一次 lane 任务，但不会绕过 decode lane、不会提高其 priority，也不会一次填满完整目标。它只执行该页按现有 staged policy 允许的下一档，因此 current 的常规水位和 lane 保留能力不变。

## 未采用

- 再次增加 visible role：只能在进入视口后补救。
- source listener 直接调用 DecodeSession：绕过 lane、revision 与 staged policy。
- source wake 后填满 targetWatermark：可能让邻页长批次占用 decoder。
- 定时轮询 waitingSource：制造无字节变化的重复调度。

## 验收

- source-ready 页面无需 observation、角色变化或 current 切换即可出现 `decodeRefill sourceWake=true`。
- current decode 被阻塞时，低优先级 prefetch source-ready 页仍能在另一个 decode lane 槽完成 frame 0。
- source-ready→frame 0 延迟不再出现数秒至数十秒的角色依赖长尾。
- 不重新引入 `PageRole.visible`，窗口仍为前 7 / 后 3。
