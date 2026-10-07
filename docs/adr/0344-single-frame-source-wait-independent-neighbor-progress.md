# ADR 0344: Single-frame source wait and independent neighbor progress

- Status: Accepted
- Date: 2026-09-30

## Context

The latest device export, `zic-debug-trace-2026-09-30T09-36-50.jsonl`, follows a slider jump with current page index 20 waiting on source. Neighbor index 21 seals at 10.065446s and promotes at 10.078906s, but receives no external first-frame grant until a new vertical drag at 28.331161s promotes it to transition. Its grant follows at 28.347355s and first frame at 28.410543s.

`StagedDecodeRefillPolicy` returns only a transition candidate whenever an unfilled current is ineligible. That bootstrap rule protects animation's initial shallow waterline, but it also blocks ready, already-admitted one-frame static demands behind another static page's source wait. Source notifications remain pending; a later role change releases the work. A failing Coordinator regression confirms `DownloadState.promoted` with no first-frame request and a waiting current, without involving UI, runtime transforms or provider I/O.

The selected current's source also has a separate 22.239395s runtime-open interval. This evidence does not prove that scrolling caused that source operation to complete, or that its bytes were already available. This decision removes the confirmed cross-page first-frame block; it does not claim to shorten source/runtime latency.

## Decision

1. Eligible current bootstrap remains first, including single-frame current.
2. A current with `targetWatermark=1` that cannot execute may release an eligible existing `targetWatermark=1` neighbor, or a real viewport transition's one frame.
3. No deeper neighbor animation waterline may run through this exception. Multi-frame current bootstrap retains its existing speculative-neighbor block.
4. Selection remains in `StagedDecodeRefillPolicy`; source revision notifications, DecodeLane and external-presentation grants keep their existing ownership and lifecycle.
5. Keep the existing encoded/decode/upload windows, lane capacities, speculative grant cap, cache residency authority and network/body-flow policy. Add no Reader wake timer, synthetic observation, reload or retry owner.

## Validation

- Policy regression first returns null for a ready single-frame neighbor behind a waiting single-frame current. The repaired policy selects one frame by the existing priority order.
- Separate regressions retain animated-current and multi-frame-neighbor blocking, plus existing current/transition priority tests.
- Coordinator regression first fails with neighbor promoted and no presentation request. After repair, the neighbor receives a grant without another observation; the current also receives its grant when its own bytes arrive.
- Pipeline regression submits scrub then idle once and completes the neighbor loader independently. Detached first-frame readiness must follow while current bytes remain unavailable.
- Repository/toolchain and fresh device results are recorded in `docs/audits/slider-static-source-wait-2026-09-30.json`.
- The final-source required-toolchain gate passes. The complete `11-56-26` Profile trace shows an existing source-ready one-frame neighbor refilling while current waits on local artifact hydration; current later consumes its own source wake and presents without user scrolling. This cached run does not verify the original runtime-open latency.
