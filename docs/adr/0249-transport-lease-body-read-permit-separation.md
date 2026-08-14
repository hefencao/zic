# ADR 0249：transport/source lease 与 body-read permit 分离

## 状态

Accepted

## 背景

dev.268 将 live response 与 body-read permit 分开后，parked response 可以释放读取额度而保留同一 `ByteResponse/StreamIterator`。dev.269 又把 demanded parking 与 inactive retention 分开，避免仍有 consumer 的 response 被 retention cap 淘汰。但 2026-08-14 01:26 的 dev.270 真机 Trace 显示 source/provider 建连阶段再次明显变慢：origin `sourceRequestPlanMicros` 中位约 1.02 s、`sourceHostOpenMicros` 中位约 0.62 s，完成的 source-loader open 中位约 1.60 s；同时 `globalRunning` 可达 17–20，所有观测到的 origin HTTP response 均为 HTTP/1.1。

根因不是 body-read 5 路本身，而是 `active=body-read permit` 后，parked live response 不再消耗任何 NetLane 容量。一个 parked response 虽然不继续请求下一块 body，仍然真实占有 source/request-plan/open 后的 transport/HTTP response lifetime。于是“normal5”只约束 body consumer，却不再约束实际 source/live-response 并发，Venera 单 invocation gate 与 host connection 两端都可能累积大量工作。

## 决策

1. NetLane 明确拥有两个正交资源：
   - **transport/source lease**：从 source/provider task admission 到 live source response 结束，代表真实 request-plan/open/socket/response lifetime；
   - **body-read permit**：允许已持 transport lease 的 task 请求下一块 source body。
2. `normal5 + current reserved1` 同时约束两个资源，但两者可独立释放/恢复。`active`继续只表示 body-read permit，新增 `transportLeases` 表示 transport/source lease。
3. flow/demand parking只释放 body-read permit；只要同一 source response 仍被保留，task继续持 transport lease。parking 因此不会重开 response，也不会绕过 transport 并发上限。
4. durable artifact-cache body一旦确认由本地 immutable authority 提供，task必须同时释放 body-read permit与transport lease；后续 body 只归 `ArtifactCacheReadScheduler`，但 physical task本身可以继续存在。
5. 删除独立 `maxInactiveParkedResponses` 容量 owner。inactive response retention 不再按“parked数量”另设第二套限额；它天然受仍持有的 transport lease 上限约束。
6. 当新的 demanded normal task 因 transport lease 饱和无法 admission 时，NetLane只可回收 `demanded=false + responseRetained + no body-read permit + transportLeaseHeld` 的 inactive parked response，记录 `downloadEvicted(evictionReason=inactive-transport-lease-reclaim)`。仍有 demand 的 parked response不是 normal reclaim victim。
7. current 保留既有 reserved handoff / high-priority destructive authority。已有 live current response恢复body读取只竞争body-read permit；新的 current 若需要transport lease，可使用reserved handoff，并在reserved也饱和时按统一restart-cost rank选择真正占用所需资源的 victim。
8. `globalRunning`不再作为网络并发计数：它可以包括已释放transport lease的durable-artifact local-body task。Trace必须分别记录 `globalActive/globalReadPermitLimit` 与 `globalTransportLeases/globalTransportLimit`。

## 后果

- 3/7 working set、physical task lifetime、live transport response、body-read pacing、本地 artifact replay 各自有明确 owner。
- demanded parked response继续保留原response，但不能把5路网络约束绕成十几/二十条HTTP/1.1 live response。
- inactive response无需另一个固定数量阈值；只有真实 transport lease pressure 才触发淘汰。
- 不改变 previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、priority1000、preemptionThreshold40 或 normal5+current reserved1。
