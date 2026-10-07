# ADR 0292: Platform-vsync effective cadence boundary

## Status

Accepted in dev.313 as an observation-only root-cause split. No frame-rate or scroll behavior intervention is active in production Reader.

## Trigger

The dev.312 cross-device run rejects Android ARR as the shared root. Both devices are API 36 and report a 120Hz display; the low-performance device reports `displayHasArrSupport=false`, while the high-performance device reports `displayHasArrSupport=true`. In both runs the dev.312 Window policy was actually applied (`currentBalanced=false`) and post-lift ballistic cadence failure remained.

The stronger device does not show evidence of simple CPU/GPU starvation. Its ballistic cadence median is 28.606ms and it contains many Choreographer system-frame gaps with only a few milliseconds of main-thread CPU. The weaker device also reproduces the problem. The existing Flutter `readerFrameTiming` healthy summaries reveal a second important boundary: despite both displays reporting 120Hz, the dominant Flutter frame cadence is already near 60Hz. Scrolling healthy summaries are about 16.478ms on the low-performance device and 16.124ms on the high-performance device; high-device dragging is about 16.144ms. Therefore a simple touch-held 120Hz to post-lift 60Hz transition is not supported by the current evidence.

The current native Choreographer probe only exports >=20ms outliers, so it cannot answer whether Android gives the app a normal ~8.3ms callback cadence and Flutter consumes only every other pulse, or whether Android/OEM scheduling already gives the app ~16.7ms callbacks. That missing fact is now the highest-information boundary.

## Decision

Keep `ReaderRuntimePlugin` on `android.view.Choreographer`. While a vertical Reader is mounted, continue the existing bounded outlier ring, but also aggregate every native Choreographer frame interval into a low-cost two-second summary. Export `platformFrameCadenceSummary` with count, sum, min/max and fixed bins `<10ms`, `10-14ms`, `14-18ms`, `18-20ms`, `20-25ms`, `25-35ms`, and `>=35ms`, plus display refresh / ARR-support metadata when available.

The summary is observation-only. It MUST NOT schedule a Flutter frame, alter ScrollPosition/ScrollPhysics, request a frame rate, toggle touch boost, alter Window refresh policy, interpolate position, or become Reader/Pipeline input. The dev.312 ARR adapter and its historical evidence remain in source, but production `ReaderRuntimeScreen` no longer activates it while this measurement is taken.

## Falsification / next split

Compare `platformFrameCadenceSummary` against the already-existing `readerFrameTiming` summaries during the same vertical continuous run:

- If native Choreographer is dominated by `<10ms` (~8.3ms) while Flutter remains ~16ms, freeze Android/OEM app scheduling as the primary explanation and move into Flutter engine Animator/vsync consumption. A later controlled Flutter-version A/B may then be justified; old Flutter issues are not root-cause proof.
- If native Choreographer is dominated by `14-18ms` (~16.7ms), the effective cadence has already been reduced before Flutter framework frame production. Investigate Android/OEM app frame-rate scheduling/override and only then design a Reader-scoped frame-rate vote A/B.
- If native normally runs near 16.7ms and its low-CPU 25-35ms bins align with ballistic gaps, treat platform pacing as the direct cadence source and capture Perfetto/System Trace around Choreographer, frame timeline, SurfaceFlinger and display scheduling.
- If native is near 8.3ms and the long native gaps do not align with Flutter misses, continue with engine-level frame-consumption instrumentation rather than Reader hot-path optimization.
