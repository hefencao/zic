# ADR-0002: First Sprint Vertical Slice

## Status

Accepted and implemented as the initial repository baseline.

## Decision

第一个 Sprint 只建立本地静态章节闭环：manifest、Reader、Observation、HeuristicPolicy、DemandPlan、fake coordinator 和 trace。

明确不实现真实下载、artifact、Rust WebP、texture、GIF 和 adaptive policy。

## Rationale

这使 UI、policy 和 session 边界可以先通过确定性测试稳定下来，避免在状态模型尚未固定时引入 native 生命周期和网络恢复复杂度。

## Exit criteria

- 100 页本地章节可解析。
- LTR/RTL/vertical 模式有明确 UI 路径。
- 固定 observation 产生确定性 DemandPlan。
- current/transition/next/previous 的最低 demand 有测试。
- fake coordinator 可记录 apply/detach trace。
