# ADR 0356: Idle vertical geometry does not produce velocity

- Status: Accepted
- Date: 2026-10-01

## Context

Normal Profile export `03-20-04` reuses a Reader session at `t260446053`.
Without content input, entry first reports logical position115.0 and then the
physical center115.5 with velocity97.867 pages/s. `_verticalVelocityFor` excluded
scrub input but differentiated idle geometry against the integer entry baseline.

## Decision

Idle vertical observations synchronize the existing physical baseline and report
zero velocity, as absolute scrub input already does. Real dragging and scrolling
continue through the same measured-velocity path. No observations, current page,
coverage or geometry are suppressed. Scheduling, motion phases, physics, windows
and resource owners remain unchanged.

## Validation

Two failing-first widget variants with provisional and warm measured ratios
reproduce nonzero idle entry velocity. The regressions also require real dragging
to retain measured velocity. All95 Reader/control tests and the2148-test/Rust22 full gate pass. Normal
Profile session reentry preserves page148: all37 idle observations report zero;
8 real motion observations retain nonzero measured velocity. Its complete2914
events contain zero failures.
