# ADR 0330：Reader navigation membership 与 resource execution projection 分离

状态：Accepted

## Context

ADR 0329 已关闭 navigation state 直接拥有 resource window 的错误：slider scrub / jump 不得把正常前7/后3 working set 压成 current-only / visible-only。该修复消除了 demand detach/rebuild，但只靠 50ms latest-wins 仍不足以限制快速 scrub 的无效工作：一秒拖动仍可提交约20个真实 viewport 目标，而每个 transient 目标若按 stable policy 执行，会让新窗口继续发起 encoded source、decode warm 与 presentation prepare。

`ReaderObs` 已同时携带 current、visible coverage、interaction、target、logical position、velocity。问题不是缺信息，而是过去把“哪些 identity 仍属于工作集”与“这些 identity 此刻允许执行多深”混为一个 membership 开关。

## Decision

1. `currentIndex + viewport visible coverage + Pipeline-owned readDirection` 继续唯一决定 Reader logical working-set / foreground truth；canonical encoded window 保持前7/后3。navigation operation 不得通过删除 Download/Decode/Upload demand 表达成本控制。
2. Pipeline 将 interaction 投影为粗粒度 `ResourceInteractionPhase`：`stable`、`motion`、`transientPreview`。它是 execution configuration，不是第二套 membership owner；raw pointer-rate velocity/logicalPosition 不直接生成连续 scheduler 权重。
3. `scrubbing` 属于 `transientPreview`：
   - current/transition/真实 visible DownloadDemand 使用 `EncodedWorkMode.localOnly`，可复用/恢复已有本地 authoritative bytes，但不得增长 remote source；
   - 同一3/7中的 hidden DownloadDemand 使用 `retained`，只保留 logical/physical identity；
   - DecodeDemand 保留 baseline membership，visible/current 最多请求一帧，hidden `targetWatermark=0`；
   - UploadDemand 保留 baseline identity，只有 foreground page `prepareOutput=true`；hidden output 不发起新 prepare，但已有 resident output/retention bookkeeping 仍可更新。
   - vertical slider scrub必须允许当前已visible页的authoritative source ratio在pointer-up前进入Reader geometry，并以selected current center做layout correction后重发visible coverage；这只修正foreground truth，不扩张hidden执行深度。
4. scrub 结束进入 stable phase 时，Pipeline 必须即使 roles/visible membership 不变也重新投影 execution configuration；同一 Download claim/task 原位恢复 `full`，不得 detach/reacquire。
5. Sessions 将 `EncodedWorkMode` 映射为 physical `TransferWorkMode`。`retained/localOnly` 不创建新 network task；已存在 physical task 只在 NetLane 上 `demanded=false / priority=0` park，同一 task key 保留。`localOnly` 仍可执行已有 local preparation。required completion claim 始终提升为 `full`。
   `localOnly/full -> retained` 是 local execution permission 的撤销，不是普通 rank migration：pending/active durable local preparation 必须立即收到 cancellation；bounded slot 仍等旧 operation Future 真正退出后释放，因此不会突破并发上限或制造第二 local scheduler。
   physical 聚合必须先按 work dimension、再在同一执行层级比较 priority：无论是多 consumer，还是同一 consumer 内多个 logical identity 经 equivalence 折到同一 carrier，`retained` claim 都不得把自己的高 priority 或 exact transport provider 捐给 `full` claim。network rank/provider 只从 full-capable claim（或独立 direct full consumer）导出，local preparation rank只从 localOnly/full-capable claim导出。
6. NetLane 仍是唯一 network scheduler；50MiB actual speculative encoded-read budget、normal 5 + current reserved 1、3/7、2/1 staged decode、50ms scrub coalescing均不改变。本决策不恢复 estimated whole-body admission，也不新增 UI-owned prefetch scheduler。
7. operation/coverage/direction/media-cost 等事实可以投影到各自资源轴，但不得压成一个“总权重”再跨层解释。encoded I/O、decode depth、presentation prepare、retention、rank、provider authority 的安全语义不同；新增维度必须进入现有 typed projection，并以粗粒度状态避免 frame-rate scheduler churn。

## Consequences

快速 slider 拖动仍只每50ms推进最新 viewport，但中间窗口不会因为保留完整3/7 claim 就自动做满3/7的远程预取/解码/上传。current/visible 是 correctness authority，interaction 是 work-depth configuration。vertical unknown geometry不得把“尚未测得”伪装成“不可见”：当前页source ratio到达后，scrub仍须更新真实coverage，而不是等release恢复full work。
