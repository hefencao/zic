# ADR 0168：Adjacent Previous 使用普通槽压力抢占而非 Current Handoff

## 状态

Accepted。补充 ADR 0167 的 logical-detach 生命周期语义；不取代 current=1000 的 bounded handoff，也不改变 previous=780、normal network=5 或 preemption threshold=40。

## 证据

`zic-debug-trace-2026-08-09T09-43-55.jsonl` 说明 dev.184 已解决一部分问题，但 admission 仍存在独立缺口：

1. current 的执行交棒明显改善。多次 inactive current 提到 priority 1000 后，`downloadStarted` 已能在约 0–44 ms 内出现，说明“pre-open activeRun 被误当 receiving retained”的主要问题已经收敛。
2. previous policy 本身正确。revision 21 中 adjacent previous 从 660 提到 780，`active=false`；同一时刻仍有 priority 760、740 等较低 active work。previous 没有获得普通槽，直到约 1.866 s 后一个 760 active transfer自然完成才 `downloadStarted`。
3. revision 29 中另一个 previous=780 约 46 ms 后启动，恰好发生在两个旧 active task收到 cancellation并物理失败退出之后。这说明普通 permit真实释放后，780 的队列顺序并无异常。
4. trace 还存在已确认 `receivingRetained=true` 后降为 active priority 0 的远离窗口 transfer。ADR 0167要求这类流在没有压力时保留是正确的；问题是现有 NetLane 只有 highPriority/current 阻塞任务能触发 victim preemption，所以 retained=0 仍可能无限早于 waiting previous=780 占用 normal slot。

只提高 previous priority、扩大 network并发或把 previous 塞进 current reserved slot都会掩盖 admission 缺口并破坏既有边界。

VibeVenera继续只读作为调度参考：running receiving 可以在 inactive 时保留，但 stronger waiting work应形成真实 scheduler pressure；取消中的任务仍必须物理退出后才释放 permit。ZIC 保留自身明确的 previous=780 与 current=1000 角色数值，不机械复制其 rank 公式。

## 决策

1. `NetLane` 增加可选 `pressurePreemptionPriorityFloor`；默认关闭，避免改变其它调用者语义。
2. Reader network lane 将该 floor 配为 780。priority >= 780 且 `< highPriorityThreshold(1000)` 的 blocked normal work可形成普通槽 pressure。
3. normal pressure仅调用既有 `_preemptLowestRunningFor`，并继续要求 incoming 与 victim 的 priority 差至少 40；每次 pump只请求一个 victim unwind。
4. normal pressure **不能**使用 current-only reserved handoff。victim 的 lane/bucket permit在真实 task结束前保持占用；previous只能在普通槽真正释放后启动，因此 normal network上限仍为5。
5. 若 current handoff 已 active，暂不叠加 normal-pressure cancellation；先让 current handoff的物理退出/交棒收口，避免形成并发取消瀑布。
6. receiving logical detach仍按 ADR 0167：没有真实 in-window pressure时 priority 0 retained transfer继续原连接；当 adjacent previous或更高 normal pressure真实等待且满足差值门槛时，允许同一 scheduler通过 TaskControl取消它让槽。
7. decode/upload lane不启用该 floor；它们现有 current-only handoff和固定角色水位保持不变。

## 后果

- previous 不再被 retained-background=0 或明显更低的 speculative active transfer长期挡住直到自然完成。
- current 的 max+1 handoff仍是唯一可临时超过 normal lane上限的路径；previous积极性提高但不会扩大并发。
- 短时前后翻页仍能复用已 receiving transport；只有真实更重要的窗口需求到来才牺牲该复用。
- 后续设备验证应测量 `previous priority 780 -> victim cancellation/physical exit -> previous downloadStarted`，而不是继续调高 priority 数值。
