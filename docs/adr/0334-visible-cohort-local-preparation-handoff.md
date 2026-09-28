# ADR 0334：Visible cohort local-preparation handoff

状态：Accepted

## Context

ADR 0332 修复了 slider scrub 的 center anchor、immediate next/previous priority 对称和 next2 降级，
并在当时的证据下保留了 composition local preparation 的严格 max2。
后续当前生产树 Profile Trace 证明，这个“严格 2”本身仍会把一个与页面语义无关的顺序泄漏到三页真实 viewport。

连续纵排 scrub 可以同时报告 `[previous, current, next]` 三页真实可见。
在 transient preview 中三页都有 `localOnly` execution permission：
current 为 1000，两侧 transition 都为 900。
旧 max2 先接纳 current 和 stable claim/插入顺序中较早的 transition；
另一侧虽然同样真实可见、同优先级，却只能等待第一个 operation 实际退出。
fresh Profile `zic-debug-trace-2026-09-28T13-26-45.jsonl` 中，
该第二个 900 preparation 的额外 queue wait 多次落在约 3.7–15.4ms。
这不是 readDirection、next/previous priority 或 NetLane 的语义，
而是 generic operation cap 把稳定 sequence/page order 变成了 presentation tie-break。

简单全局把 local preparation 改成 3 仍然不可接受：
它会扩大后台/跨 Reader/跨 revision 的本地执行并发，并推翻 ADR 0332 对资源边界的约束。
需要的是只覆盖“同一次真实 viewport 已经需要三页”的 operation-lifetime handoff。

## Decision

1. composition local preparation 的普通 operation-lifetime 上限继续为 2。
   后台、hidden next2/far、跨 Reader、跨 accepted revision 以及非 `localOnly` 工作都继续受该上限约束。
2. 当且仅当已经有 2 个 active local preparation，且 pending candidate 与这 2 个 active work：
   - 来自同一个 Reader transfer consumer；
   - 来自同一个 accepted demand revision；
   - 当前 effective work mode 都是 `localOnly`；
   - 都携带 `viewportVisible=true`；
   owner MAY 使用唯一一个 viewport handoff overlap，使 active operation 暂时达到 3。
   第四个 operation 永远不得由该规则接纳。
3. `viewportVisible` 是 Reader observation 经 Pipeline 形成的 typed execution fact。
   `HeuristicPolicy` 必须从真实 `visibleCoverages`/current observation 写入 `DownloadDemand.viewportVisible`，
   `LiveCoordinator` 只原样投影到 `TransferDemand`；
   transfer owner 不得从页号、拖动方向或 current/next/previous 猜测可见性。
4. handoff 只改变 physical local-preparation operation 的重叠生命周期。
   它不得扩大 7/3 encoded membership、2/1 decode deadline、Upload/presentation 并发或 presentation raster budget，
   不得增加 NetLane slot/worker，也不得允许 `localOnly` 打开 remote source。
   persistent body I/O 继续由唯一 `ArtifactCacheReadScheduler` 分块调度。
5. 不满足 handoff 条件时，既有 max2、dynamic rank、preemption margin、candidate grace 和真实退出后补位语义完全不变。
   handoff 活跃时新 work 也不得形成第四个 slot；高优先级抢占仍走同一原有 preemption 状态机。
6. ADR 0332 的 selected-page center anchor、pending ratio commit 和 immediate next/previous 对称 priority 决策继续有效。
   本 ADR 仅取代 ADR 0332 Decision 5 中“local preparation 在任何情况下都严格为 2”的假设。

## Evidence

修复前 fresh Profile `zic-debug-trace-2026-09-28T13-26-45.jsonl`：
- 三页同时可见的快速 forward 样本中，在 prev/current/next 都能于 200ms 内给出首帧的 matched subset，
  `next - current` 中位约 +18.21ms；
- 同一类 revision 常见 admission 为 1000 -> 900 -> 等待中的 900，
  后一个同优先级 visible transition 额外等待约 3.7–15.4ms；
- 该顺序来自 operation/claim 稳定顺序，不是 slider 拖动方向。

加入 bounded viewport handoff 后，重新执行
`./tool/build_android.sh profile` 并由
`tool/prepare_reader_device_test.py --mode profile --display 0`
安装同一 Profile/release-native 构建。
长双向 scrub Trace `zic-debug-trace-2026-09-28T14-15-30.jsonl`：
- 48 次生产 `viewportHandoff=true` admission；
- handoff queue wait median 158us、p95 747us、max 1.654ms；
- `activePreparations` 从未超过 3；
- 快速 forward 三页可见 matched sample n=19，`next - current` 中位约 +0.01ms；
- reverse matched sample n=11，`next - current` 中位同样约 +0.01ms。

把 `viewportVisible` 进一步收口为 `ReaderObs -> DownloadDemand -> TransferDemand` 的显式 typed fact 后，
重新构建并安装最终源码 Profile；`zic-debug-trace-2026-09-28T14-33-10.jsonl` 再次确认：
- fast-forward 三页可见 matched sample n=17，`next - current` 中位约 +0.01ms；
- reverse n=10，中位约 +0.01ms；
- 37 次 production handoff，queue wait median 166us、max 1.684ms，`activePreparations` 从未超过 3，`taskFailed=0`。

`next - previous` 仍可能为正，因为 previous 经前一轮 scrub 已有 resident raster 时本来就应该更早显示。
这属于 cache-history reuse，不得通过故意拖慢热页来制造数值对称。
另有少数 Flutter raster/decode/host-lifetime 长尾仍属于 presentation 层独立问题，本 ADR 不用扩大 local/network 并发掩盖它们。

回归验证同时保持：
- ordinary local preparation 最多 2 个；
- blocked high-priority preparation 的既有 grace/preemption 行为；
- `localOnly` remote gate；
- Pipeline 7/3、2/1 与 visible-output 规则。
