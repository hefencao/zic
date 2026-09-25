# ADR 0325: Vertical drag displacement resampling

## Status

Accepted

This decision re-opens only the finger-down drag path from ADR 0288/dev.309. It
does not overturn the dev.310 finding that the old 28–43ms post-lift ballistic
cadence holes were not caused by touch sampling.

## Evidence

The 2026-09-24 report changed the measured symptom from generic frame delay to
visible per-frame displacement non-uniformity: Profile build/raster stays within
budget while adjacent presented frames move by very different distances. The
same behavior is visible without scrcpy and on a separate high-performance
device where Mihon renders the same comic smoothly.

A fresh no-scrcpy diagnostic run first separated cadence, geometry and motion.
With the display running at 120Hz, platform/frame/ScrollUpdate cadence was
predominantly below 10ms and vertical scene geometry residual remained zero,
yet a controlled constant-speed ADB drag still produced large adjacent-frame
velocity changes. In `zic-debug-trace-2026-09-24T12-25-28.jsonl`,
representative one-second drag windows had:

- 14/98 adjacent velocity steps above 20%, mean step ratio 10.69%, max 77.84%;
- 13/103 above 20%, mean 9.94%, max 30.16%;
- 15/92 above 20%, mean 10.58%, max 53.23%;
- a mixed drag window reached a 255.28% step.

The post-lift ballistic control remained smooth: adjacent measured velocity
changed only about 2.8–5.6% and never crossed the 20% threshold. This preserves
the dev.310 conclusion that touch resampling is not an explanation for
ballistic frame-cadence holes.

Flutter 3.44.9 leaves `GestureBinding.resamplingEnabled` false by default and
documents touch resampling as the framework mechanism for smoothing touch
sensors whose sampling frequency is low or not an integer multiple of display
frequency. A single-variable A/B enabled only that built-in resampler without
changing `samplingOffset`, ScrollPhysics, geometry, Pipeline policy or frame
scheduling. In `zic-debug-trace-2026-09-24T12-28-48.jsonl`, matched
constant-speed drag windows fell to:

- 0/113 steps above 20%, mean 0.0043%, max 0.0171%;
- 0/115, mean 0.0045%, max 0.0154%;
- 0/116, effectively zero within the injected linear trajectory;
- 0/80, mean 0.0021%, max 0.0084%.

The post-frame RenderBox residual probe becomes phase-sensitive while Flutter
resampling is active because the framework may dispatch the resampled pointer
after paint but before another diagnostic post-frame callback. Those transient
diagnostic residuals therefore are not interpreted as geometry writes; the
acceptance signal is the actual frame-to-frame ScrollPosition displacement
sequence.

## Decision

`reader_runtime` owns a process-global, reference-counted
`FlutterReaderTouchResamplingLease`. A vertical continuous Reader acquires the
lease after its `ReaderController` direction is established and releases it
when leaving vertical mode or disposing the route. The first lease preserves
the prior `GestureBinding.resamplingEnabled` value; the final release restores
it. Nested or overlapping Reader routes cannot restore the setting early.

`reader` remains framework-input agnostic and MUST NOT import or mutate
`GestureBinding`. The lease uses Flutter's built-in resampler exactly as
provided. ZIC MUST NOT tune `samplingOffset`, synthesize pointer positions,
add a custom interpolation/Ticker, force frames, or alter ScrollPhysics to mask
motion. Pipeline windows, NetLane, geometry ownership, page retention and
presentation policy remain unchanged.

The default Flutter sampling offset adds input latency by design. Device
acceptance therefore requires both visual smoothness and acceptable
direct-manipulation latency. If latency is unacceptable, do not compensate by
inventing a ZIC-specific offset; re-open the framework/input boundary instead.

## Relationship to dev.309/dev.310

dev.309 asked whether resampling explained `scrollCadenceOutlier` gaps.
dev.310 correctly falsified that broad claim because 20/22 relevant outliers
were `dragDriven=false` ballistic events. ADR 0325 asks a different question
with a new metric: whether healthy-cadence finger-down frames receive uneven
displacement. The matched A/B answers yes. The historical ballistic evidence
remains valid and any future ballistic cadence regression must continue to be
investigated independently.
