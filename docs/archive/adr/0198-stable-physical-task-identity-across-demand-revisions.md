# ADR 0198：Demand revision 期间保持稳定的 Physical Task Identity

- Status: Accepted
- Date: 2026-08-11
- Version: 0.31.0-dev.217

## 背景

dev.216 将 exact `DownloadId` 的 registry/network/retry/writer 提升到 composition `DownloadTransferOwner`，但实现中的
`_ensureDownloadTask()` 在发现已有 `_networkTaskKeys[id]` 后只更新 priority，没有停止后续 submit。Reader policy 每次 role/revision
变化都可能为同一个 `DownloadSession` 生成新的 NetLane key；旧 task 尚 queued/active 时，新 task 会被视为独立工作并争用同一 run/writer。

设备 Trace 直接观察到该违约：`sessionBusy` 与 `writerBusy` 不是网络错误，而是 physical owner 自己制造的重复执行；前者又被普通
RetryPolicy 当作可重试错误，进一步占用 NetLane 槽位并放大预下载失效。

## 决策

1. exact `DownloadId` 在 NetLane 中已有 queued/active task 时，physical task key保持稳定；demand role/priority/revision变化只调用
   `updatePriority`，随后立即返回，禁止重新 submit。
2. 只有 `_networkTaskKeys[id]` 指向的 key 已经不再存在于 NetLane 时，owner 才可把它识别为 stale tracking并创建下一代 physical task。
3. task真正开始前再次核对 `_networkTaskKeys[id] == taskKey`；已被退休/替代的 lane entry不得进入 `DownloadJob.beginRun()`。
4. scheduler admission同时把 `session.hasWriter` 与 `activeRun`视为不可建立第二physical task的状态。
5. `sessionBusy/writerBusy` 不作为本轮增加网络retry/fallback的理由；根因必须由physical task identity invariant消除。

## 后果

policy revision仍可实时改变queued/active transfer rank，但不再扩大task数量；NetLane容量重新代表不同图片的物理工作，而不是同一图片的
重复调度实例。dev.216的composition owner方向保留，verified TransferKey-before-acquire暂缓到该调度回归经设备复验之后。
