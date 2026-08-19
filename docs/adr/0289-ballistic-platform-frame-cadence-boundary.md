# ADR 0289: Ballistic platform frame-cadence boundary

## Status

Accepted as an observation boundary in dev.310; not yet a jitter fix.

## Evidence

The 08:20 dev.309 device Trace contains 22 `scrollCadenceOutlier` events. 20 are `dragDriven=false` ballistic updates after finger lift; their gap median is 28.2005ms and max 42.888ms. Representative 20–43ms gaps carry inertial pixel deltas consistent with skipped intermediate samples rather than a discontinuous ScrollPosition write. `readerFrameTiming` independently contains repeated 30–42ms intervals while build/raster/total-span are commonly only a few milliseconds. Application-side input resampling therefore cannot explain the dominant ballistic symptom.

## Decision

Remove the dev.309 touch-resampling production lease and retain only `dragDriven` attribution. `reader_runtime` owns an Android-only Choreographer cadence probe while a vertical Reader is mounted. The native callback records only frame-time/callback gaps >=20ms or callback lag >=8ms into a bounded 256-sample ring. Dart drains at a 2s cadence and maps native monotonic timestamps into the shared Trace as `platformFrameCadenceOutlier`.

The probe is diagnostic-only: it MUST NOT mutate ScrollPosition, ScrollPhysics, Reader/Pipeline state, texture policy, resource windows, or call Flutter `scheduleFrame`. It MUST NOT synthesize pointer/position samples.

## Falsification split

- If ballistic `scrollCadenceOutlier`/`readerFrameTiming` gaps coincide with `platformFrameCadenceOutlier`, the next owner is Android main-thread/Choreographer/display delivery; inspect native main-looper work and system trace before changing Reader logic.
- If Android Choreographer remains near one display interval while Dart/Flutter still skips to 28–43ms, freeze Android-main hypotheses and inspect Flutter engine Animator/frame-pipeline pacing.
- The probe is not proof that Flutter upstream issue reports share the same cause; external reports are corroboration only until this device split is observed.
