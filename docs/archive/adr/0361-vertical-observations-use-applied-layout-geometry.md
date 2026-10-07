# ADR 0361: Vertical observations use applied layout geometry

Status: Accepted

## Context

The fresh Release trace at 08:58:16 records a decode-ahead prefix adoption
during dragging, followed by a false reverse velocity of -29.18 pages/s and
then +16.50 pages/s. A frame-end ratio adoption can precede an already queued
observation callback. The new geometry then interprets old physical pixels
before ListView applies the atomic correction. A valid widget regression
publishes 3.617 -> 2.617 -> 3.617 without further pointer movement.

Two incoming prefix measurements before the next layout expose the same
mismatch in anchor preparation: the second correction uses new geometry at
old pixels and loses the first prefix delta. The failing regression moves
the current page by 600 pixels despite an unchanged pointer.

## Decision

Reader retains a reference to the immutable geometry already captured by
ListView's extent builder. Physical observations, scene diagnostics and
top-anchor preparation use that snapshot until the next list build. Planned
extents and absolute navigation commands continue to use the current geometry.
Back-to-back measurements therefore calculate cumulative correction from one
physical anchor. The existing builder publishes coverage after layout.

Controller/composition replacement clears the reference. There is no cloned
geometry, new frame loop, timer, queue, resource owner or network eligibility
gate. The reference is navigation layout state; Pipeline output ownership,
NetLane, workers, windows and budgets retain their existing contracts.

## Validation and limits

The two valid failing-first logs and the focused navigation/zoom results are
recorded in `docs/archive/audits/loading-chapter-plugin-regressions-2026-10-01.json`.
An initial test incorrectly compared a pre-layout rectangle after real pointer
movement; that test defect is excluded from product evidence.
Required gate2162/27 + Rust22 and ordinary Release device acceptance pass.
The complete6153-event export covers13 active dimension updates with no fast
false logical observation; independent controls/tail/slider artifacts pass.
This defect does not attribute every loading cost or final display pause.
