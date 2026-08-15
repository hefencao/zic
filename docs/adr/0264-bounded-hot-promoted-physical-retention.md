# ADR 0264：有界 hot promoted physical source retention

状态：Accepted

接受版本：dev.285。

## 背景

16:22 dev.284 真机 Trace 否证 ADR 0263 的 UI composition cache-boundary 假设：page18/page19 的短命 mount/dispose 已被 guard 吸收，但用户在同一固定区域上下滑仍明显抖动，因此 dev.284 mount-travel keep-alive 必须回滚。

同一 Trace 暴露更上游的资源分界：`PhysicalTransferRetention` 在 promoted physical session 变 idle 后立即把全部候选经 ordinary artifact handoff settle 后退休。约 41.7 秒内记录 84 次 `retired-promoted-resident`，并在多个 Reader window 边界出现一次 5 个 session 的退休 burst。反向跨回同一边界时，这些刚退休的 immutable page 又从 persistent artifact 通过 `artifact-cache-stream` / `consumer=session-copy` 重建 fresh physical generation。dev.269 审计已记录同一 persistent artifact 2–3 次完整 session-copy，并把“promoted resident idle 后立即 retire”列为候选根因；本轮设备数据把该候选与固定边界抖动直接对应起来。

## 决策

1. promoted immutable physical session 的 hot retention 继续属于 downloads composition owner `PhysicalTransferRetention`；Reader、Pipeline、NetLane 与 texture 不持有该预算。
2. 默认最多保留 8 个 idle promoted session，按既有 touch order 形成 LRU tail。预算内 session 不因普通 demand/window detach 立即退休，附近反向 traversal 可复用同一 physical/source generation。
3. 超过预算后只退休超出的 oldest victim。退休前仍必须等待既有 `PromotedArtifactCacheHandoff.settleAutomatic()` 成功；handoff 不可用/失败或 session 重新变 active 时必须保留 hot owner。
4. 该预算只保留 physical generation/session authority，不改变 encoded previous3/next7、decode2/1、holder、texture、NetLane transport/body-read permit 或 ArtifactCacheManager byte ownership。`residentBodyBacked` session 本身不复制正文；durable body 仍属于既有 immutable source/cache authority。
5. unfinished partial 继续使用独立的 32-session / 256 MiB hot-partial pressure policy；不得把 promoted count 与 partial byte budget合并。
6. 保留历史 retirement action 名称，压力退休附加 `reason=hot-promoted-retention-pressure`、`maxIdlePromotedSessions` 与 `retainedIdlePromotedSessions`，便于设备确认普通边界不再触发全量 retire。
7. dev.284 UI composition mount-travel guard 回滚；ADR 0263 状态改为 Superseded。dev.280–283 其余已由设备单独验证的 geometry/target/texture修复不因本 ADR 回滚。

## 拒绝方案

- 继续扩大 page-host keepAlive/cacheExtent：dev.284 已由设备否证为抖动根因，只会增加 UI 常驻。
- 让 Reader 在手势期间禁止 physical retirement：会把 transfer retention policy 反向注入 UI interaction owner。
- 提高 NetLane parked/response 容量：重复工作来自已完成 promoted physical generation 被销毁后的本地 durable session-copy，不是网络 response 不够。
- 永久保留所有 promoted session：会重新出现 dev.233 的无界 composition physical registry 增长。
- 立即重构成 durable artifact 直接 file-backed Reader source：可能进一步降低 session-copy，但 ownership/生命周期改动更大；先验证 bounded hot source 是否足以消除本轮固定边界 churn。

## 验证

- 在同一局部区域反复上下跨 Reader window boundary 时，最近离开的 promoted pages 应留在 `retainedIdlePromotedSessions<=8`，不再每次边界都出现 5-session `retired-promoted-resident` burst。
- 同一 persistent identity 的 `artifact-cache-stream consumer=session-copy` 次数应显著下降；附近 reverse traversal 应直接复用原 physical session。
- 只有 idle promoted 数量超过8时才允许出现 `retired-promoted-*`，且必须带 `reason=hot-promoted-retention-pressure`。
- 若上述 source churn 闭合而固定区域仍抖，再进入 Sliver/layout/compositor frame timing；不得再次扩大 Reader composition retention。
