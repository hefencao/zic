# dev.305 纵排抖动：scheduling migration 控制面审计

## 输入与边界

- 唯一代码基线：用户新上传 `zic.tar.gz`，版本字段为 0.31.0+304。
- 设备证据：`zic-debug-trace-2026-08-19T02-44-48.jsonl`。
- 用户假设：主要可能是 UI jank / UI-isolate 同步阻塞，小概率是滑动位置不均匀跳变。
- 本审计不继承旧临时工作树；此前实验只作为已落入新基线源码/文档的冻结历史阅读。

## 证据重新分层

### 位置跳变目前缺乏支持

149 条 `pageLayoutSnapshot` 均保持 `extentDeltaPx=0`，`layoutResidualPx` 固定，2x2 transform 为 identity。已有 Reader geometry probe 没有出现与肉眼大幅抖动量级相符的 box 位置或 extent 不连续，因此本轮不修改 Sliver、ScrollPosition、anchor、physics、sourceCanvas 或 pixel alignment。

### missed-vsync 仍然存在

113 个导出 `readerFrameTiming` entry 经过 dev.304 健康帧摘要后代表约 923 个真实 frame。异常 raw timing 的 frame interval 最高约 85.545ms；滚动阶段仍反复出现约 30–35ms 间隔，而许多对应 build/raster 只有约 1–3ms。首次 static SurfaceProducer blit仍可有较高成本，但反向 resident-reuse 阶段同样存在长 gap，因此 native first-present 不是统一解释。

### 合法页边界控制面仍偏重

87 个 `pipelineReconcileTiming` 的总体中位为 2.319ms；15 个 download diff 为 `1 added / 10 changed / 1 removed` 的典型页边界中位为 8.387ms，最大 11.284ms。典型 revision 的 11 个 download scheduling mutation、3 个 changed decode 与 2 个 changed upload 仍按顺序在 UI isolate 上处理。

源码审查确认三种职责耦合：

1. `DownloadSession._setDemandPriority()` 对 existing scope 的纯 scheduling priority 变化仍创建 `demandApplied` Map/TraceEvent；真正的 session lifecycle/snapshot 已在 dev.303 与其分离，因此该事件不再携带新的 lifecycle fact。
2. `LiveCoordinator._reconcileDownloads()` 把 added 与 changed 合并为 `observed`，使普通 priority/role changed 反复 `registry.get -> onDownloadObserved -> ingress attach -> _watchSource`。physical source generation 并未因此改变。
3. `DownloadTransferOwner._replaceDemands()` 对已有 physical claim 的 reason/priority/flow migration仍重走完整 `_upsertClaim` ownership path。只有 scheduling metadata 变化时，exact identity、checksum proof 与 completion intent 实际保持不变。

## dev.305 修改

- existing-scope download priority update只更新 scheduler state，不再生成 `demandApplied`；scope首次attach仍保留 demand lifecycle Trace。
- decode/upload added identity继续生成 `decodeDemand`/`uploadDemand`；changed role/priority由已有 `policyDecision + pipelineReconcileTiming` 聚合归因，start/state/frame/failure细粒度Trace全部保留。
- LiveCoordinator新增 concrete `DownloadSession` observation map：新增identity总是observe；changed identity只有registry解析到不同physical session对象时才重新attach ingress/source watch。
- DownloadTransferOwner新增严格 scheduling-only existing-claim fast path：physical/exact id、checksum、completion intent必须全部不变；否则机械回退到完整claim establishment。fast path仍刷新lease priority、deferred/retry scheduling state、NetLane rank/flow target，并在无task时保留原`_ensureDownloadTask` wake edge。

## 未宣称已经关闭的部分

当前 Trace 中仍存在若干 30ms+ gap，其时间窗内没有已记录的 policy/reconcile/pageHost/texture 事件。它们可能来自分配/GC、未Trace的同步 listener、Flutter/platform callback 或系统调度，也可能是前序控制面突发的后效；现有证据不足以唯一裁决。因此 dev.305 是针对已量化 8–11ms 合法reconcile的可证伪降载，不应提前写成最终根因关闭。
