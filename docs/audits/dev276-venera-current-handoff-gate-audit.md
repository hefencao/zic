# dev.276 Venera current handoff gate 审计

## 设备事实

05:37 dev.275 Trace中25次origin source read的request-plan中位约0.96 s；19次实际runtime invocation的`sourcePlanGateWaitMicros`中位约669 ms、最坏约3.89 s。bridge network调用中位仍为4次，其中cache hit中位3、origin中位1，说明dev.275 resolver cache owner并未成为主要回归点。

快速viewport handoff中可同时出现旧current与新current的source-plan工作。dev.274已保证current优先进入source admission，但runtime gate内部仍可能让旧current invocation继续占唯一context。

## 源码根因

`_RuntimeInvocationGate`已有两种重新评估入口：新waiter入队时按incoming priority检查active；queued waiter向上跨current阈值时再次检查active。反向变化缺失：controlled active invocation没有priority subscription，因此旧current从1000降到820/900后，已经等待的新current不会触发新的差值比较。

这不是resolver cache miss、NetLane transport lease或partial hydration问题，也不需要提高`maxConcurrentInvocations`。

## dev.276 收口

- controlled active invocation持有自己的priority subscription，并在release时统一注销。
- 只有active从`dynamicPreemptionPriorityThreshold`之上向下跨出，且当前最高waiter仍为current-class，才调用既有`_maybePreemptControlledActive`。
- 既有40-point threshold、requestId cancel与“物理退出后才转single permit”保持。
- 新回归覆盖old current 1000 + new current 1000：初始不互抢；old current降到820后请求取消；新current只能在旧invocation真实退出后开始。
- 既有820→700、previous780 jitter不抢占回归继续保留。

## 后续设备判据

下一份Trace优先比较current cold plan的`sourcePlanGateWaitMicros`。若旧current已降级而新current仍出现秒级gate wait，继续检查native requestId cancellation实际退出时延；若gate wait已收敛而open仍慢，再分别分析`sourcePlanRuntimeInvocationMicros`与`sourceHostOpenMicros`。
