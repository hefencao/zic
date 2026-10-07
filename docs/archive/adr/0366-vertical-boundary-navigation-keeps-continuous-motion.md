# ADR 0366: Vertical boundary navigation keeps continuous motion

Status: Accepted

## Context

The fresh4104-event ordinary Release has a-95.69pages/s head-arrival sample.
Its clock interval is healthy16.589ms, and the last measured velocity is-1.80.
The physical viewport center would remain near1.56, but navigation deliberately
returns first-page logical position0 at the actual ScrollMetrics head. Passing
that semantic override to velocity sampling fabricates1.59pages of travel.
The analogous tail override and departure from either endpoint have the same
coordinate discontinuity. This is distinct from ADR0364's accepted sampling
clock/request/pointer contracts and does not justify reopening those components.

## Decision

Keep current/stable first/last navigation identity, logical endpoint value,
coverage and boundary commands. For velocity only, use the continuous viewport
center from the same immutable applied ListView geometry and actual pixels.
Idle/scrub observations establish that physical baseline; real content input
advances it under the existing clock/request retirement contract. Layout-only
observations keep the prior velocity and do not advance the sampling clock.

Sparse outliers record physical motion and semantic navigation coordinates
separately. No velocity clamp, timer, queue, network eligibility, scheduler,
budget, geometry correction or authority owner is introduced.

## Validation and limits

Real-gesture controlled-clock head and tail regressions fail before the change:
head expected-3.75 but actual-128.75pages/s; tail expected3.75 but actual66.25.
They preserve endpoint current/logical identity and also verify departure using
actual pixel displacement. Reader navigation/zoom/geometry focused86 passes.
Required full gate2172/27 + Rust22 passes with the existing3 quarantines.
Ordinary minified three-ABI Release builds; its installed hash matches.
The complete7682-event export has8 active dimension updates, no sampling
outlier or taskFailed, active build/raster maxima3.979/6.811ms and reconcile1.359ms.
Previous entry remains68/68 through controls reopen; next remains1/198.
Idle slider first frame arrives30.868ms after release, before content motion.
One36.524ms ScrollUpdate interval and independent entry/display criteria remain.
Content-motion observations do not establish final presentation or visual
smoothness. Evidence is in the loading/chapter/plugin regression audit.
