# ADR 0345: Pending slider release and navigation completion

- Status: Accepted
- Date: 2026-09-30

## Context

Fresh Profile verification of ADR0344 exports `zic-debug-trace-2026-09-30T10-37-52.jsonl`. After the slider selects page index 40 and the pointer is released, Reader continues to report `scrubbing` for 151.036 seconds without any further input. Pipeline remains `transientPreview` with zero full encoded demands, and no new source task starts. This is a distinct input-phase defect, rather than the original trace's 22-second runtime source open.

The final slider jump may physically reach its target before its post-frame observation updates Controller.currentIndex. Pointer-up then submits the same final target through the non-null requested-page path. Repeating the same offset produces no ScrollEnd notification. That path previously left Reader's old scrubbing phase untouched; its completion emitted another scrubbing observation even though Controller.pageScrubbing was false. The existing settled-before-release test cannot cover this ordering.

## Decision

At the existing valid vertical page-request completion boundary, finish a residual scrubbing phase only when Controller has already ended its scrub. Synchronize the velocity baseline to the actual ScrollMetrics and ReaderVerticalGeometry before the existing observation. Schedule the existing deferred-ratio commit and retain the selected geometry anchor until that commit converges.

Retain mounted/direction/navigation-revision/requested-target checks. Completion cannot overwrite a real dragging or scrolling phase. Do not add an observation timer, an alternate release listener, a reload, or Reader-owned transport/scheduler state. Pipeline continues to consume the real input-phase observation and restores full execution on the same claims.

Pointer-up can also flush a different final target. Synchronize the physical baseline immediately after that absolute jump, before a queued ScrollEnd observation, and use actual geometry again at idle completion. A later zero-velocity observation cannot undo earlier false direction learning. Check all release observations, rather than only the final one.

## Validation

The new Reader widget regression submits a final scrub target and pointer-up before pumping the final layout. Before repair it fails with expected idle, actual scrubbing. After repair all 38 Reader navigation tests pass, including physical position/zero phase velocity, deferred ratios and interrupted-animation drag ownership. Final toolchain and device evidence is recorded in `docs/archive/audits/slider-pending-release-2026-09-30.json`.

The final-source required-toolchain gate passes. The complete `11-56-26` Profile trace verifies one forward slider sequence: its first release observation is idle with velocity zero, Pipeline resumes stable/full execution, and cached page49 presents 113.054ms later without vertical input. Later end-of-list layout correction remains a separate geometry observation; the run does not establish cold-origin or reverse-gesture coverage.
