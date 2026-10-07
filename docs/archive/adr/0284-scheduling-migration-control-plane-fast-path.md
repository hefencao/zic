# ADR 0284：Scheduling migration 不得重走 identity / lifecycle 热路径

## 状态

Accepted

## 背景

用户以新的 `zic.tar.gz` 作为唯一代码基线，并提供 02:44 continuous 纵排真机 Trace。149 条 `pageLayoutSnapshot` 的 `extentDeltaPx` 始终为 0，`layoutResidualPx` 恒定且 transform 为 identity，因此当前没有证据支持把明显抖动解释为 Sliver/page box 位置跳变。相反，导出的 `readerFrameTiming` 代表约 923 个真实 Flutter frame，仍可见大量 30–35ms 间隔，异常帧的 build/raster 多数只有约 1–3ms，符合 missed-vsync 而非持续布局/光栅超预算。

此前 dev.301–304 已分别收口 semantic-no-op revision、lane 多次 pump、Trace→snapshot 隐式广播和 DebugTrace 数据结构热路径；但本 Trace 的 87 个 `pipelineReconcileTiming` 仍显示合法页边界控制面不够便宜。15 个常见 `1 added / 10 changed / 1 removed` download-window migration的 reconcile 中位约 8.387ms，最大约 11.284ms。时间轴与源码审查显示 existing physical identity 的普通 role/priority migration 仍逐项产生 demand telemetry、重复 Reader ingress/source-watch observation，并在 transfer owner 重走完整 claim establishment。

## 决策

1. Demand lifecycle Trace 只描述需求身份进入/退出，不承担每次 scheduling priority 迁移的逐项日志。`DownloadSession` 对 existing scope 的 priority update 不再生成 `demandApplied`；scope 首次 attach 与 detach 仍保留生命周期 Trace。
2. `decodeDemand` / `uploadDemand` 的逐项 Trace保留新增 identity；existing decode/upload role/priority migration由一次 `pipelineReconcileTiming` 的 changed cardinality 与权威 `policyDecision` 归因，不再为同一页边界额外生成每项生命周期事件。真实 decode/upload start/state/frame/failure Trace 不变。
3. Reader ingress/source-watch ownership绑定 physical `DownloadSession` 对象 generation，而不是 scheduling priority。LiveCoordinator 必须记住已观察的 concrete session；新增 demand 或同一 logical id 解析到新的 physical session 时建立/重绑，普通 changed demand 不得重复调用 ingress attach/source watch。
4. `DownloadTransferOwner` MAY 对 existing claim 使用 scheduling-only fast path，但仅当 physical id、exact id、expected checksum 与 completion intent 均未变化。该路径可原位更新 reason/priority/flow target、claim revision 与 NetLane scheduling，并保留原有 task wake edge。exact identity、integrity proof、completion intent 任一变化或 claim/session 缺失时 MUST回到完整 `_upsertClaim` ownership path。
5. 本决策不改变 HeuristicPolicy、priority 数值、3/7 download、decode previous1/next2、NetLane normal5+current reserved1、sourceCanvas、Reader geometry、texture/presentation 或 dev.299 current±2 static projection continuity。

## 可证伪条件

同一区域下一份设备 Trace 应直接比较典型 `1/10/1` 页边界的 `pipelineReconcileTiming.reconcileMicros` 与 missed-vsync 数量。基线中该 reconcile 中位约 8.387ms、最大约 11.284ms；若 dev.305 后明显下降且 30–50ms frame gap 同步减少，说明这条 UI-isolate 控制面链得到设备支持。若 reconcile 已降到很小而明显抖动/长 frame gap 仍大量存在，必须冻结本路线并转查未被 Trace 覆盖的 UI-isolate allocation/GC、Flutter/platform callback 或 frame scheduling；不得继续通过扩大窗口、geometry/scale/pixel-snap 补偿掩盖问题。
