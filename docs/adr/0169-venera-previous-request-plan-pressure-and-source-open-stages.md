# ADR 0169：Venera Previous Request-Plan 压力与 Source-Open 分段观测

## 状态

Accepted。补充 ADR 0166/0168；不增加 Venera JavaScript 并发，不改变 Reader NetLane 5+1、previous=780、current=1000 或 40 分抢占门槛。

## 证据

`zic-debug-trace-2026-08-09T10-05-26.jsonl` 显示 dev.185 已基本修复外层 network admission：5 个可完整匹配的 inactive previous 660→780 到 `downloadStarted` 延迟分别约 3.093、14.354、13.596、5.034、6.508 ms，中位 **6.508 ms**。因此不能再用提高 previous priority、扩大 network=5 或让 previous 借 current reserved handoff解释剩余慢页。

同一 trace 中，`downloadStarted` 到 origin response 可见的长尾仍与启动 rank明显相关：current=1000 的 5 个样本中位约 2,413.0 ms；820 为 3,267.7 ms；800 为 6,172.0 ms；previous=780 的 6 个样本中位约 **5,133.8 ms**、最大约 7,747.6 ms。现有 `ArtifactCacheTransport.openMicros` 把 source request-plan/runtime gate 与 host HTTP response-open 聚合为一个数字，无法继续定位两段占比。

Venera runtime 为避免共享 JavaScript 上下文状态竞争，仍必须单 invocation。dev.177/183 只允许 current=1000 对低 rank active controlled invocation施压；因此 NetLane 已及时 admission 后，previous=780 仍可能在嵌套 Venera request-plan gate 后等待较低 rank invocation自然完成。这是外层 dev.185 相同 pressure 语义在下一层 owner 上缺失，而不是需要第二个 JavaScript context。

## 决策

1. Venera `_RuntimeInvocationGate` 保持 `maxConcurrentInvocations=1`，把 current-only preemption 开关收敛为 `controlledPreemptionPriorityFloor=780`。
2. incoming controlled invocation 只有在 priority>=780 且比 active invocation 至少高40分时才请求 `requestId` cancellation；active 已收到 preempt request 后不重复请求。780 对 active760 的20分差不抢占。
3. cancellation 不释放 permit。旧 invocation 仍必须完成 native abort / JavaScript `finished(requestId)` 并物理退出后，单一 permit才按实时 priority交给 waiter；因此 previous 的积极性不以并发第二个 Venera JS 为代价。
4. `ByteResponse` 增加只读 observational `diagnostics`；调度、retry、cache逻辑禁止读取它做决策。
5. source resource transport记录 `sourceRequestPlanMicros`、`sourceRequestPlanCacheHit`、`sourceHostOpenMicros`、`sourceOpenPath`、`sourceRetryUsed`，并由 ArtifactCache origin `artifactSource/sourceRead` trace透传。它只拆现有 `openMicros`，不改变请求、framing或缓存所有权。
6. Mihon runtime 保持既有并发限制，不启用该 Venera 单上下文 pressure floor。

## 后果

- previous 已进入外层普通 network slot 后，不再无条件继承 Venera 单 invocation FIFO；低至少40分的 request-plan work可被同一 TaskControl/requestId取消。
- Venera 仍严格单 invocation，不新增 runtime context、scheduler或并发。
- 下一份设备 trace可直接区分慢页主要耗在 source request-plan/runtime gate 还是 host HTTP response-open，从而避免继续围绕笼统 `openMicros` 调参。
