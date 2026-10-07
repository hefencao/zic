# ADR 0203：Live Reader scrub 与 foreground demand 边界

- Status: Superseded in part by ADR 0329
- Version: 0.31.0-dev.222

> ADR 0329 supersedes only the `scrubbing -> current-only RoleWindow` membership rule. The live scrub lifecycle and latest-wins navigation seam remain accepted.

## Context

dev.220 为阻止 slider 148→248 一次拖动触发大量完整 prefetch replans，把 `onChanged` 降为 UI-local preview、只在 `onChangeEnd` 提交 navigation。该方案隔离了资源调度，却破坏 Reader 基本交互：拖动时页码/viewport不实时变化。

dev.221 11:35 真机 Trace 同时证明此前 resident replay 与 physical trace 问题已明显收口，因此本轮不应回退 download owner，也不应恢复“每个 slider index 都展开完整 7/3 window”的旧耦合。

## Decision

1. slider scrub 是真实 Reader navigation。`onChangeStart` 建立 scrub lifecycle，`onChanged` 通过 `ReaderController.scrubToPage()` 实时推进 requested/current viewport，`onChangeEnd` 结束 scrub。
2. `ReaderObs.interaction` 新增 `scrubbing`，作为 navigation/presentation 与 resource planning 之间的显式语义边界，而不是让 UI 直接操作 Pipeline。
3. `RoleResolver` 遇到 `scrubbing` 时只发布 `current` role；因此中间页只形成 current 的 foreground download/decode/upload，禁止展开 next/previous/near 的 7/3 prefetch window，也不保留 previous-current overlay。
4. Reader→Pipeline 继续使用 dev.219 的 `enqueueObservation` latest-wins microtask seam：UI/viewport 可以逐帧跟随 scrub，尚未开始 reconcile 的更旧 observation 可被最新位置覆盖；不增加固定毫秒 debounce。
5. scrub end 即使最终页已经被 viewport acknowledge，也必须推进一个 navigation revision，使 ReaderView 发布非-scrub observation；正常完整窗口由同一 Pipeline diff 恢复，不建立第二 planner。
6. 普通 PageView drag/scroll、程序化 jump 与 vertical navigation 保持现有 interaction 语义；只有 slider scrub 使用 `scrubbing`。
7. 不修改 NetLane、并发、水位、retry、cache、transport、resident replay、physical transfer owner 或 verified TransferKey。

## Consequences

- thumb、页码与可见 Reader page 在拖动期间实时同步。
- 中间页仍可获得 current=1000 的 foreground source/decode/upload，已有 cache/output 可立即显示，未命中时也只启动当前页工作。
- 长距离 scrub 不再把每个中间页扩张成 11-download / 4-decode / 4-upload 的完整邻域计划；松手后最终页恢复正常 prefetch。
- ADR 0201 的 physical trace fan-out 与 ReaderBinding presentation 决策继续有效；其中“scrub只在release提交”由本 ADR supersede。
