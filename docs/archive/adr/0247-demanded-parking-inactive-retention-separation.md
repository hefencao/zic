# ADR 0247：demanded flow parking、inactive response retention 与 durable artifact read 解耦

Status: Accepted in `0.31.0-dev.269`.

## 背景

dev.268 将 live response 与 NetLane body-read permit 分离，但仍把所有“未持 read permit”的 running task 统一计入 `maxParkedResponses=10`。23:32 真机 Trace 中 17 次 `parked-response-eviction` 有 9 次 victim 当时仍为 `demanded=true`：这些 response 只是满足 5/3/2/1 flow credit 后暂停读取，仍属于当前 consumer working set，却因全局 parked 数量达到10而被真实取消。随后同 identity 再次 `downloadStarted`。

同一 Trace 还显示 persistent artifact body 已由 `ArtifactCacheReadScheduler` 调度，却仍以 remote bucket 占 NetLane body-read permit完成 9–18MiB session-copy。于是网络 response 读取与本地 durable artifact replay 被两个 scheduler 同时约束。

## 决策

1. NetLane 的 body-read permit、demanded flow parking 与 inactive live-response retention 是三个不同事实。
2. `demanded=true` 且已释放 read permit 的 live response 是**仍被需要的 physical work**，不得计入 inactive retention 容量，也不得成为 retention eviction victim。
3. 只有 `demanded=false`、仍保留 live source response、且已释放 read permit 的 task 才计入 `inactiveParkedResponses`。NetLane composition owner 以 `maxInactiveParkedResponses` 有界管理它们；超限只允许 `inactive-response-retention-eviction`。
4. Reader profile 不再配置 socket/response retention 容量。3/7 只决定 consumer demand，不拥有 transport retention policy。
5. read permit 被释放并不总意味着“parked response”。`CancelToken.releaseResponseReadPermit(responseRetained: ...)` 显式说明 live network response 是否仍被保留；NetLane 只有在 `responseRetained=true` 时才纳入 response-retention 统计。
6. `ByteResponseBodyAuthority.artifactCache` 的 durable immutable body 在 authority 已确认后立即释放 NetLane body-read permit，并以 `responseRetained=false` 继续本地读取。其 body 带宽唯一由既有 `ArtifactCacheReadScheduler` 管理；NetLane 不再同时把本地 cache body 计为 remote body-read work。
7. `running` 仍表示 physical task 存活；`active` 只表示 NetLane body-read permit；Trace 分别发布 `globalReadPermitReleasedTasks`、`globalDemandedParkedResponses`、`globalInactiveParkedResponses` 与 `globalInactiveParkedLimit`，禁止再用一个 `globalParkedResponses` 混合解释。

## 不做

- 不提高 parked cap 来掩盖 demanded response 被误杀。
- 不按 next/previous 距离、Range capability 或 flow target 再增加 eviction 例外。
- 不把 `ArtifactCacheReadScheduler` 合并进 NetLane。
- 本轮不改变 promoted resident session 的内存保留策略；重复 durable artifact replay 作为独立 Reader-local encoded-source/retention 问题继续审查。

## 后果

working set、network body-read permit、inactive live-response retention、durable artifact local read 四种资源各有单一 owner。一个仍有 consumer demand 的 flow-paused response 不再因无关页面增减而被 retention cap 销毁；本地 artifact replay也不再挤压真实网络的5路读取额度。
