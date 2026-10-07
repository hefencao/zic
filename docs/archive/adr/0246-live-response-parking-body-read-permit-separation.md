# ADR 0246：live response parking 与 body-read permit 必须分离

> dev.269 / ADR 0247 supersede 本文“所有 parked response 共用 Reader=10 上限”的实现：demanded flow pause 不属于 inactive retention；仅 `demanded=false` live response 受 NetLane composition retention cap。
- Status: Accepted
- Date: 2026-08-13

## Context

dev.267 已把 Reader 3/7 working-set membership 与 physical task identity 分离，但 14:54 真机 Trace 仍证明 response lifetime 没有真正独立：一个 `pseudo-retained` consumer-paced response 在最后 claim 消失后虽继续保持 task identity，后续只要 normal pending 因5路容量受阻，NetLane 就以 `inactive-reclaim` 取消同一个 `CancelToken`。rhttp direct 的 task cancellation 会执行 `cancelToken.cancel()` 与 `StreamIterator.cancel()`，因此 live response 被真实销毁；再次进入窗口只能新建 `downloadStarted`，Range 被服务器忽略时继续产生 full-body prefix catch-up。

此外，Range-capable speculative response 仍存在第二条主动断流路径：flow credit 满足后 `DownloadJob` 抛 `DownloadFlowSuspended`，随后主动 `iterator.cancel()`。因此 `pseudo-retained` 只是状态名；系统仍把“live response 是否存在”和“是否占 NetLane 5路读取额度”绑定在一个 active slot 上。

## Decision

1. NetLane 将 physical running task 与 body-read permit 分成两个资源事实：
   - `running`：task/response 仍存活；
   - `active`：当前持有 body-read permit、允许申请下一块 response body 的任务。
   normal5 + current reserved1 只限制 body-read permit，不再等价于 live response 数量。
2. `CancelToken` 只读投影 scheduler 的 `demanded/flowTargetFrames/priority`，并提供同一 task 内的 `releaseResponseReadPermit()` / `acquireResponseReadPermit()`。这两个操作只迁移 permit，不触发 cancellation、不结束 DownloadJob、不释放 writer、不替换 response。
3. 对具有 source body flow capability 的 response：
   - consumer demand 消失，或 positive 5/3/2/1 flow credit 同时满足 structural frame 与 decoder playable-prefix floor时，DownloadJob 在安全 read boundary flush authoritative pending bytes，然后释放 read permit并保持同一 `StreamIterator` idle；
   - demand/target/playable-floor 改变后，同一 task 重新竞争 permit；获得 permit 后继续原 response，禁止第二次 `downloadStarted`；
   - `consumerPacing` 只说明不能证明真实 upstream byte backpressure，不再授权主动关闭 response。Range capability也不再决定 flow-credit 满足时是否关闭 response。
4. 删除 `DownloadFlowSuspended`、`pseudo-suspended`、`pseudo-retained`、`retainFlowResponse` 与 normal `inactive-reclaim`。不存在“先结束 response，再用 partial/proof 假装 pause”的 flow-control 路径。
5. structural frame proof 是 physical generation fact，写回 `DownloadSession.networkFlowSatisfiedFrames/networkFlowProofLength`；Reader target 不是 proof owner。真实 response eviction 后，若当前 positive target 已由 retained partial + playable floor满足，可不重新开网；target0/current 或更高 target 才需要恢复网络。
6. parked live response 必须有界。Reader stable profile 的 logical window 为 previous3 + current + next7，因此允许最多10个 speculative parked responses。超过上限时，NetLane 优先淘汰 `demanded=false`、低 priority、较旧的 parked task，并以 typed `parked-response-eviction` 明确记录真实 response destruction。不得把该 eviction 伪装为 pause。
7. current-only destructive preemption继续只针对真正持有 body-read permit、实际阻塞 current admission/resume 的 task；parked response 不占 permit，不得作为“腾5路”的 preemption victim。
8. rhttp direct 的 async body generator 在 downstream iterator idle 时不得主动触发其 `finally/abort`；只有 stream 完成、显式 cancellation、provider dispose 或 parked-response eviction 才允许结束 response。transport 不拥有 parked-pool policy。

## Consequences

- 3/7 滑动、确认转向甚至一批 claim 同时 detach，只会使对应 active task 在下一安全 read boundary进入 `demanded=false` response parking；不会因为 normal pending 需要读取额度而销毁 response。
- 多个 parked HTTP/1.1 response 可能继续占 socket，且 `consumerPacing` 不能保证 native 层完全不继续缓冲。因此 parked pool 必须严格有界；这是用有界 live-response state 换取避免重复请求/prefix replay的显式资源权衡，而不是隐藏扩大 normal body并发。
- ADR 0239/0240 的 adjacent/non-Range retention flag、ADR 0245 的 `inactive-reclaim` 子句被本 ADR supersede；ADR 0245 的 working-set/physical-task lifetime 分离原则仍成立。
- previous3/next7、decode previous1/next2、5/3/2/1 body credit、holder 7/5/3/2、normal body-read 5 + current reserved1 均保持。
