# ADR 0195：在提升 Image Transfer Registry 前先建立 Consumer Claim 语义

- Status: Accepted
- Date: 2026-08-11
- Version: 0.31.0-dev.214

## 背景

dev.213 仍由每个 `PipelineReaderSession` 创建自己的 `DownloadRegistry`，并由对应
`LiveCoordinator` 持有 network task、retry、terminal failure 与 deferred catch-up 状态。
`DownloadSession` 同时持有可写 artifact 和由该 Reader 的 media runtime 创建的 native
`Ingress`。因此“把所有 Reader 的 DownloadRegistry 合并成一个全局 Map”并不是安全的
ownership 迁移：它会让不同 Reader 的 coordinator 竞争同一个 writer/run，且同一
`DownloadSession.ingress` 无法同时代表两个 Reader-local decode runtime。

VibeVenera 的参考实现先建立了更基础的约束：image alias 在 `DownloadIdentity` 前解析；
`DownloadSession` 接受按 scope 的 demand lease；effective priority 取所有 demand 的最大值；
logical detach 只移除该 scope，物理 session 的取消/驱逐另有 owner。ZIC 在 dev.213 缺少这一
层，只有一个 `_demanded` bool。

## 决策

1. dev.214 先把 download demand 改为 scope-based `DownloadDemandLease`。
2. 同一 `DownloadSession` 可同时存在多个 consumer claim；每个 claim独立更新 priority、独立 detach。
3. `effectivePriority` MUST 为当前 scoped claims 的最大 priority，不得相加。
4. Reader path 的 `LiveCoordinator` MUST 使用 scope claim，不得由 `DownloadJob` 再偷偷 attach
   legacy demand。
5. Reader demand移除时，如果同一 session仍有其它 claim，MUST 保持物理 transfer，不得 cancel；
   active NetLane task只降到剩余 claim 的最高 priority。
6. direct chapter/offline 等尚未迁移的调用者可暂时使用 `DownloadJob.attachLegacyDemand=true`；
   这是兼容入口，不是目标组合语义。
7. dev.214 **不**把 `DownloadRegistry` 提升为 composition-global，也不共享 hot partial。
   在此之前必须先把 Reader-local native ingress 从物理 transfer state拆成 consumer projection，
   并把 network task/retry/terminal owner 从 Reader-local `LiveCoordinator` 移到真正的 transfer owner。

## 为什么不直接完成 global registry

当前一个 `DownloadSession` 同时承担：

- artifact/writer/run/validators/resume 等物理传输状态；
- Reader media runtime 的单一 `Ingress`；
- source listeners；
- 单一 demand bool。

同时 `LiveCoordinator` 还承担：

- `_networkTaskKeys`；
- retry round/pending；
- terminal failure；
- deferred catch-up；
- Reader-local decode/upload orchestration。

因此只移动 Map 会制造两个 coordinator 对同一 transfer 的 cancel/retry 竞态；只共享
`DownloadSession` 又会把 native ingress错误共享到不同 Reader decode runtime。dev.214 先移走
其中最独立、也是后续所有共享必需的“谁需要资源”语义。

## 迁移后边界

当前生产边界：

```text
Reader A demand ─┐
                 ├─ scoped claims ──> DownloadSession effective priority=max
Reader B demand ─┘                  (能力已建立；生产仍未共享 registry)

PipelineReaderSession
  ├─ Reader-local DownloadRegistry / LiveCoordinator   [仍待迁移]
  ├─ Reader-local native Ingress / DecodeRegistry      [必须保持局部]
  └─ Reader-local Upload/presentation                  [保持局部]
```

下一安全阶段应变为：

```text
ImageTransfer owner (composition)
  ├─ TransferKey / DownloadSession physical state
  ├─ writer / network task / retry / retained partial
  └─ scoped consumer claims
          ├─ Reader ingress projection -> local decode/upload
          ├─ prefetch claim
          └─ chapter/whole-comic command claim
```

## 现有补偿机制分类

- `VerifiedArtifactReusePlan`：保留；强证据 identity/mapping 能力仍需要，并应在后续
  `TransferKey` acquire 前复用。
- page mapping persistence：保留。
- verified equivalence registry：保留；当前仍服务 immutable artifact，后续可提供 transfer-key proof。
- durable partial copy：暂时兼容层；冷启动/进程边界仍需要，不能因 hot transfer共享而删除。
- session partial handoff：暂时兼容层；待 hot partial成为 ImageTransfer state 后重新评估。
- artifact handoff：保留，immutable artifact仍由现有 cache owner持久化。
- equivalent-full promotion takeover：暂时兼容层；verified transfer key前移后部分路径可能可删除。
- retained download session：暂时兼容层；Reader retention 与 transfer retention后续拆分。
- Reader-local DownloadRegistry：目标删除/降级为 consumer projection registry，但 dev.214 不机械删除。

## 后果

正面：

- demand ownership不再是一个全局 bool；
- priority aggregation和 logical cancel具备可测试语义；
- 后续共享 transfer 时不会因为一个 Reader detach 天然杀死其它 consumer；
- 与 VibeVenera 的 demand lease时序对齐，但没有复制其缓存系统。

代价/未完成：

- 生产仍不能跨 Reader join hot partial；
- retry/terminal failure仍位于 Reader-local `LiveCoordinator`；
- `DownloadSession.ingress`仍是 Reader-local native source；
- chapter/whole-comic仍未降级成共享 ImageTransfer claims。
