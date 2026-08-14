# ADR 0250：cold partial hydration 前移到 network admission 之前

## 状态

Accepted in `0.31.0-dev.272`。

## 背景

dev.229 将 verified cold partial restore 收到 physical prepare；dev.257 又把 local completion 放到 provider lookup / `downloadStarted` 之前，但当时明确保留了一个待设备证据确认的边界：async `prepareDownload` 本身仍在 NetLane task 内执行。

02:01 dev.271 真机 Trace 给出了该证据。已有 durable partial 的 physical identity 只有先获得 NetLane transport/source task admission 后才开始 `session-partial-handoff/restored`：page194 从 demand 到本地 restore 约 2.40s，page203 约 3.09s；page201 成 current 后也要等 admission 才开始恢复，本地 prefix 约 160ms 后才成为 physical committed source。durable partial hydration 是本地存储 / physical-session 初始化，不应等待 network/source lease。

## 决策

1. `DownloadTransferOwner` 继续是唯一 physical transfer owner，并新增每个 physical `DownloadSession` generation 一次的 local-preparation single-flight。它只负责初始化顺序，不成为第二个网络或存储 scheduler。
2. synchronous `replaceDemands()` 保持纯 demand reconciliation；若 fresh physical session 需要 `prepareDownload`，owner 异步启动 local preparation 并立即返回，不阻塞 Reader planning。
3. local preparation 在任何 NetLane task / transport lease / provider lookup 之前执行。`PartialDownloadHandoff` 仍只拥有 durable partial bytes；它恢复出的 append 可直接投影到既有 Reader-local ingress，因此 decode 可在网络 admission 尚未发生时消费 prefix。
4. preparation 完成后先执行既有 `DownloadJob.completeWithoutTransport`。若已本地完成，直接结束；只有仍 demanded 且仍需要 source/network continuation 时才提交 NetLane task。
5. demand revision 在 preparation 期间变化时只更新 claims；preparation 完成后重新读取当前 preferred claim，不跨 async boundary 固定 provider。重复 revision 必须 join 同一 preparation future。
6. local preparation 进行中不得由 idle physical retention 退休该 session。preparation 结束后仍无 demand 时不得因此创建 NetLane task。
7. local durable hydration 失败不得把本地加速路径升级为 network admission failure。owner 记录 local fallback 后只尝试一次该 physical generation 的 preparation，并允许正常 provider path 恢复；不得形成 cold-store retry loop。
8. 前移不等于无界并发：cold partial 的持久化读取与既有 durable artifact replay 共用 composition `ArtifactCacheReadScheduler`，按chunk获取动态priority lease；不得新增第二个local-read lane，也不得让3/7一次性启动11条不受控磁盘流。
9. 3/7、5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane normal5 + current reserved1、transport lease/body-read permit 模型均不改变。

## 后果

- `sourceReady`/physical committed prefix 不再受 network queue/source-open latency阻塞。
- cold partial lookup/复制与 provider request-plan、HTTP transport lease 解耦，但 physical bytes/writer 仍只有一个 owner；persistent local encoded read bandwidth继续只有既有`ArtifactCacheReadScheduler`一个调度authority。
- dev.257 的“local completion before provider admission”升级为更完整的“local physical preparation before NetLane admission”；不是新增缓存、retry 或 partial admission policy。
