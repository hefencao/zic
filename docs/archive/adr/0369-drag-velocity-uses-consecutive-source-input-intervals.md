# ADR 0369: Drag velocity uses consecutive source input intervals

Status: Accepted

## Context

The complete ordinary Release export has a drag sample timed886us with
velocity-12.21 pages/s. This remains after ADR0364/0366's independently verified
layout/request/pointer and continuous-center repairs. It must be attributed
before reopening those components or changing workers/window policy.

A temporary observation-only Profile records actual drag source timestamps,
scroll deltas and every sampling entry. Its complete3891-event export contains
537 probes. Three consecutive drag pairs have source intervals8.766/11.422/
18.664ms but callback intervals3.024/3.624/1.533ms. The same physical movement is
about1.755 pages/s using source time; callback time reports5.09/5.53/21.36.
Dispatch latency bunches real input callbacks. The motion denominator describes
callback delivery rather than the time of the input being measured.

The official API and installed SDK describe DragUpdateDetails.sourceTimeStamp
as the source pointer timestamp; proxied accessibility events may omit it:
https://api.flutter.dev/flutter/gestures/DragUpdateDetails/sourceTimeStamp.html
Context7's Flutter API index did not retrieve this property, so the exact
official property documentation and installed SDK supplied the API evidence.

The loading supplement contains16 active dimension updates and two source
timestamps that go backward408/396us. Callback fallback reports-7.95/-9.47
pages/s from a rewind shortly after forward input. The source baseline is newer
than this event; replacing it with the backdated event creates another invalid
denominator. A directional widget fails at±4.44 instead of retained∓0.833.

## Decision

Reader retains only the timestamp associated with its last real vertical motion
sample. Consecutive drag inputs with increasing source timestamps use their
elapsed source interval. First/missing/equal timestamps and genuine ballistic
sampling keep the existing Reader callback interval. Strictly backdated input
still publishes physical coverage/position, but preserves the latest valid
motion position/time and measured velocity for the next increasing input.
No elapsed motion derivative can be calculated against a newer source time.
Absolute source
time and Reader clock time are never subtracted from one another.

Layout-only and raw pointer phase observations preserve both motion baselines.
Idle/scrub baseline reset, scroll start and controller replacement clear the
source timestamp; a real non-source/ballistic sample retires it. A new drag can
interrupt ballistic before its first tick and before a queued idle observation,
so scroll start must retire the old input time without advancing Reader time.
Observation/trace event times
continue to use the composition clock. Sparse outliers expose both the chosen
sampling interval and callback interval for attribution. Sparse backdated-input
events expose the unchanged valid baseline and retained velocity; they do not
drive policy or suppress physical observations.

No timer, smoothing, velocity clamp, callback queue, gesture resampling setting,
new public contract object or downstream owner is added. Applied layout geometry,
semantic first/last navigation, slider/tail anchors, workers, NetLane,7/3 and2/1
windows, budgets and native ingress locking retain their accepted contracts.
Paged motion retains its existing callback time calculation.

## Validation and limits

Two directional controlled-clock widgets fail before the change: actual speed
is±0.460 instead of±0.833 pages/s when16ms input is delivered29ms apart. The
same fixtures verify the subsequent1ms callback burst still measures16ms input,
layout-only refresh preserves the baseline, and idle retires the old gesture
timestamp before the next gesture. A real fling interrupted before its first
tick also fails before scroll-start retirement: expected±10.42, actual±0.059
pages/s. A400us backdated input separately fails with an opposite±4.44 pages/s
instead of retained∓0.833; the next increasing input must use the last valid
baseline, including the physical coverage rewind in its net displacement.
The earlier fixture did not actually remain ballistic and is excluded
test evidence. All earlier fallback/ballistic and Reader navigation contracts
remain required.

Temporary instrumentation has been removed byte-for-byte against its saved
dirty-worktree baseline. Profile observations prove this denominator component;
they do not establish final display smoothness or close independent cadence,
entry CPU, source and original Plan acceptance. Required toolchain checks pass
2186 tests across27 Dart/Flutter suites and22 Rust tests; three Android ABI/JNI
checks pass. Fresh ordinary Release5738-event export retains15 backdated inputs
in7 sparse groups, with coverage published and the valid velocity baseline
retained. Idle slider presents518.655ms after release before further motion;
previous/next enter68/68 and1/198. A separate geometry handoff outlier remains
under ADR0370 and does not reopen this input-time component. Evidence is in the
loading/chapter/plugin regression audit.
