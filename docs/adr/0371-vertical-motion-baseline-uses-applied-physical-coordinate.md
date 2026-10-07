# ADR 0371: Vertical motion baseline uses the applied physical coordinate

Status: Accepted

## Context

The complete7611-event ordinary Release trace verifies slider wakeup, chapter
boundaries and source-manager metadata after ADR0370, but retains a different
geometry derivative anomaly. Page82 shrinks from provisional924.444px to
measured414.815px between idle and the next drag. A real prefix correction ports
the viewport by-509.630px; subsequent input moves only11.806px. The logical center
changes from82.3896 to82.8968 and is differentiated over16.280ms, producing31.151
pages/s. Input timing is healthy; the derivative compares different geometries.

Two directional widgets reproduce a visible page changing from600px to300px
with a prefix correction during the next drag. Real8px input over16ms should
measure±1.667 pages/s, but measures+26.667 and+15. The latter also invents the
opposite direction. Resetting the sampling clock on layout would repeat the
accepted ADR0364/0369 clock defect and lose unsampled input.

## Decision

Reader retains the pixel position of its last valid content-motion sample.
Its existing private ScrollPhysics reports the actual numeric dimension
correction within Reader layout. Only that real layout shift ports the pixel
baseline; repeated passes report only their actual incremental shift. No
ScrollMetrics object is retained.

Before velocity sampling, Reader evaluates both the valid baseline pixels and
current pixels in the same applied immutable geometry and viewport dimensions.
This projects coordinates without advancing the sampling clock or physical
sample. Only a valid real motion sample or existing idle/scrub reset replaces
the baseline. Backdated source events retain it while publishing their physical
coverage. Controller/composition replacement clears it.

This refines ADR0364's unchanged sampling-position language: the physical
sample and both timestamps remain unchanged by layout-only coverage; the
derived logical coordinate is expressed in the newly applied geometry.
ADR0369's source-time policy is unchanged. The notification is private within
Reader geometry/motion observation, with no new public contract or Pipeline,
transport, media, scheduler, worker, budget or window coupling.

## Validation and limits

The directional failing-first fixtures preserve the16ms source interval while
callbacks are33ms apart and layout observations intervene. The candidate passes
both directions. Existing applied-geometry, prefix-transaction, continuous
endpoint, slider, pointer/layout clock, backdated input and controller lifecycle
regressions remain required. All97 focused tests and the full2190-test/27-suite
Dart/Flutter gate,22 Rust tests and three Android ABI/JNI checks pass. Fresh
ordinary Release exports8183 and5548 events without truncation. Five and eight
active dimension updates respectively produce no motion outlier; nine sparse
groups retain16 backdated input observations without replacing the valid
baseline. Idle slider presents112.498ms after release and loading-repeat
slider80.531ms, both before further content movement. Previous/next remain68/68
and1/198. This closes only the coordinate component: one48.162ms
drag-to-ballistic callback handoff gap, entry CPU, final display, source and original Plan
requirements remain open.

Flutter's official adjustPositionForNewDimensions contract requires changed
pixels to trigger correctPixels and repeat layout; retained data here consists
only of numeric pixels. The official API and installed SDK evidence are recorded
in the loading/chapter/plugin audit after the Context7 API index did not return
the exact hook documentation.
