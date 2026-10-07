# ADR 0364: Layout observations preserve the motion sampling clock

Status: Accepted

## Context

The fresh ordinary Release export at 11:08:48 contains a reverse drag velocity
of -40.63 pages/s immediately after an incoming prefix correction. The actual
content movement is about9.2 pixels; the applied geometry is correct. A layout
observation advances the velocity baseline shortly before the next real input,
so the denominator is the callback interval rather than the input interval.

A controlled-clock regression reproduces16ms content input separated by a
layout callback500us before the next input. Expected velocity is-0.83 pages/s;
the old implementation reports-26.67. This is separate from ADR0361's stale
geometry/pixels defect and does not justify rolling back prefix adoption.

The request-retirement Release has11 active dimension updates and identifies
drag-scroll-update outliers timed69–369us after an unchanged physical baseline.
Raw pointer touch-slop promotion observes the current position, then the same
input's ScrollUpdate moves content. Both used to sample the motion clock.
A controlled-clock test expects-10.42 pages/s over16ms but reports-166666.67
because the second synchronous sample is timed from the first promotion.

## Decision

The existing post-layout observer coalesces a boolean fact indicating whether
a real ballistic ScrollUpdate needs velocity sampling. Layout-only callbacks
publish current physical coverage with the last measured active velocity,
without advancing the content sampling position or timestamp. Drag updates
continue to sample directly; ballistic updates use the existing observer.
Idle and absolute slider observations retain their zero-velocity baseline.
Raw pointer drag-phase promotion also observes coverage without sampling motion;
the ensuing ScrollUpdate remains the real physical displacement sample.

A newer direct sample retires an earlier coalesced sampling request. The queued
layout callback still refreshes coverage, but cannot resample the motion clock
from an input that has already been overtaken. A controlled notification test
reproduces this lifecycle independently of real ballistic motion.

Sparse velocity outliers record the sampling entry, prior/current positions,
interval and prior velocity in the existing trace. They do not change motion,
sampling, geometry or resource policy and do not claim final display jank.

Controller/composition replacement clears the pending sampling fact. There is
no new timer, callback queue, velocity clamp, clock, scheduler or resource owner.
Applied geometry, atomic prefix correction, released slider/tail anchors,
NetLane, workers, windows and budgets retain their existing contracts.

## Validation and limits

The failing-first log, ballistic input test and subsequent gate/device evidence
are recorded in the loading-chapter-plugin-regressions audit. The ballistic test
uses actual observed sample timestamps; its initial16ms-per-pump assumption
ignored the first zero-time simulation tick and is excluded as a test defect.
Content observation velocity does not establish final display presentation.
The first device revision still contains a -68.84 pages/s outlier; its successful
slider and chapter-boundary checks do not close motion sampling acceptance.
The request-retirement revision passes2167 tests across27 suites plus Rust22.
Its fresh7625-event Release confirms correct slider/chapter boundaries and the
remaining duplicate pointer sample. The pointer-promotion revision has89 focused
passes and a complete required gate of2168 tests across27 suites plus Rust22.
The fresh ordinary Release export has7719 events,10 active dimension updates and
no task failure or severe duplicate sampling outlier. Previous/next entries
remain68/68 and1/198; idle slider first frame arrives31.821ms after release,
before further content motion.

The retained outlier peak is5.82 pages/s rather than336.20. Two sparse input
outlier events and a41.613ms maximum ScrollUpdate gap remain observation
evidence; they do not justify clamping velocity or establish final display jank.
Acceptance covers the reproduced layout/request/pointer sampling contracts.
