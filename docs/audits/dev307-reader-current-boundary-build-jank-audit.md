# dev.307 Reader current-boundary build-jank audit

## Baseline and trigger
- Unique code baseline: formal `zic_v0.31.0-dev.306_vertical-continuous-viewport-control-plane-separation.zip`.
- Device evidence: `zic-debug-trace-2026-08-19T04-12-45.jsonl`.
- User localization: the interval immediately before leaving Reader has strong visible jitter.

## Evidence
- Around 29.945s: ~29.5ms frame interval, build ~1.4ms, raster ~1.5ms.
- Around 30.042s: ~32.2ms interval, build ~1.9ms, raster ~2.3ms.
- Around 30.450s: ~29.5ms interval with build ~13.8ms, raster ~1.5ms, total span ~16.7ms. The same boundary includes current 22→23, policy rev150, ~4.67ms reconcile, page15 host disposal and a later page25 mount.
- Static texture first copies around 30.303s (~20.1ms platform blit) and 30.965s (~11.6ms) do not align with the retained >25ms Flutter gaps; texture remains secondary for this segment.
- Existing layout evidence remains stable and does not support a large ScrollPosition/Sliver jump.

## Source ownership finding
`ReaderController.report()` updated current/stable and then called the same broad `notifyListeners()` used for navigation/rotation commands. Consumers included ReaderView's command listener, every mounted page shell, ReaderRuntime progress projection, and whole top/bottom controls. Every current crossing also immediately shifted `_ReaderPageShell._keepAliveFor()`'s current±7 center, allowing an offscreen host demotion/dispose to share the same critical frame.

## Closure candidate
- Narrow current-index projection, broad command notification separation.
- Bounded vertical keepAlive center frozen during active scroll, committed at idle/explicit jump.
- Controls/current playback/progress subscribe only to current-index projection.
- Raw ScrollUpdate >20ms diagnostic added to distinguish sparse ScrollActivity/input delivery from rendering-only missed vsync.

## Falsification
If current-crossing build spikes fall but `scrollCadenceOutlier` still reports many 25–35ms raw ScrollUpdate gaps, freeze Reader rebuild/lifecycle optimization and inspect Flutter engine/ScrollActivity/Android frame delivery. If raw ScrollUpdate cadence stays ~16ms but FrameTiming still skips 30ms+, inspect engine/platform render scheduling. Do not return to geometry/scale/pixel-snap without new displacement evidence.
