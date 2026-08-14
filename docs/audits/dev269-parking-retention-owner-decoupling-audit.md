# dev.269 parking / retention owner 解耦审计

## 设备事实

输入：`zic-debug-trace-2026-08-13T23-32-18.jsonl`，dev.268 真机。

- `transport-flow-control` 中 55 次 bounded-flow-credit park、12 次 no-consumer-demand park；40 次同 task resume 均未在 park→resume 间出现第二次 `downloadStarted`。说明 dev.268 同 response park/resume 主路径有效。
- Trace 有 17 次 `downloadPreempted`，全部为 `parked-response-eviction`；其中 **9 次 victim 当时仍 `demanded=true`**。典型 page222/page223/page221 在 positive flow credit 满足后仍属于有效 demand，却仅因 parked 总量超过10被销毁，之后重新 `downloadStarted`。
- 因而错误不在 pause 本身，而在 dev.268 把 `demanded=true` flow-paused response 与 `demanded=false` inactive retained response 共用一个 eviction pool。
- persistent artifact `sourceRead` 多次完整读取 9–18MiB；其 payload 已显示 `ArtifactCacheReadScheduler` wait/acquire，同时对应 physical task仍占 remote NetLane `globalActive`。这是本地 durable replay 与网络 body-read permit 的双重调度。
- 本 Trace 未发现 decode/upload/download state failure；generation/output 不是当前主因。

## 旧 owner 冲突

`ReaderPipelineProfile.parkedResponseCapacity=10` 用 3+7 speculative window 推导 transport live-response retention 容量，使 Reader policy 越层拥有 socket/response retention。NetLane 又只以 `responseReadPermitHeld=false` 判断 parked，无法区分“仍有 demand 的 flow pause”“无 demand 的 inactive retention”“已经切换到 artifact-cache local body”的三种资源。

## dev.269 收口

- 删除 Reader profile 的 `parkedResponseCapacity` 与 factory 参数传递。
- NetLane 改为 `maxInactiveParkedResponses`，eviction candidate 必须同时满足 `!responseReadPermitHeld && responseRetainedWhilePermitReleased && !demanded`。
- demanded flow-paused response不消耗 inactive retention预算。
- `releaseResponseReadPermit(responseRetained: false)` 表示后续 task 虽仍 running，但不存在需要 NetLane retention 的 live network response。
- durable artifact-cache body确认 authority 后立即使用上述路径释放 network permit；其读取继续由 `ArtifactCacheReadScheduler` 单独限流。
- Trace 统计拆成 read-permit-released / demanded-parked / inactive-parked，避免再从一个 parked 数字推断错误生命周期。

## 剩余问题

同一 persistent artifact identity 在本 Trace 内可出现2–3次完整 session-copy。根因候选是 promoted resident physical session 在 idle 后立即由 `PhysicalTransferRetention` settle/retire，下一 demand 再从 durable cache重建 Reader 可消费 source。它与网络 response retention 不应重新耦合；后续应单独比较“有界 hot promoted source”“durable artifact直接 Reader-local replay/低复制 source”与当前 session-copy 的 ownership/内存成本，不在本轮增加简单数量缓存。
