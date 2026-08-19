# ADR 0286: Reader position / command / scroll-lifecycle boundary

## Status
Accepted for dev.307; device verification pending.

## Context
The 04:12 dev.306 device Trace was inspected specifically around the user-marked strong-jitter interval immediately before leaving Reader. Two distinct cadence signatures coexist. Around 30.450s a ~29.5ms frame interval contains ~13.8ms Flutter build, current 22→23, an accepted reconcile of ~4.67ms and nearby page-host demotion/mount. Around 29.945s and 30.042s the frame interval is still ~29.5/~32.2ms while build/raster stay near 1–2ms. Texture first-copy work exists nearby but does not align with these long intervals, and repeated layout evidence remains stable.

Source review found four different responsibilities sharing `ReaderController`'s broad `ChangeNotifier`: navigation/rotation commands, current-page projection, every mounted page shell's active/keepAlive calculation, and whole top/bottom controls. A current-page report therefore woke command consumers and shifted the vertical current±7 keepAlive center in the same animation-critical frame.

## Decision
1. Broad ReaderController notification is command state only: direction, rotation, requested navigation/scrub command revisions.
2. Current-page projection is a narrow `currentIndexListenable`; `report()` publishes it before Pipeline consumption and does not call broad `notifyListeners()`.
3. Page active state, progress projection, subtitle, scrubber and current-page playback capability subscribe to the narrow projection. Whole controls remain command-driven and must not rebuild only because current index crossed a page boundary.
4. Vertical page-host retention remains exactly the existing bounded current±7 policy, but its center is frozen for the duration of one active continuous scroll. ScrollEnd/idle or explicit discrete navigation commits the center once. This is not the superseded dev.284 expanding travel-union guard and does not increase the steady-state retention radius.
5. Raw vertical `ScrollUpdateNotification` cadence gaps >20ms with non-zero pixel movement are recorded as diagnostic-only `scrollCadenceOutlier`. The event must not schedule a debug UI frame or drive scrolling, layout, Pipeline, policy, or smoothing.

## Non-goals
- No ScrollPhysics, geometry, anchor, sourceCanvas, texture/presentation, 3/7, decode2/1, NetLane or priority changes.
- No interpolation or synthetic scroll frames.
- This ADR does not claim the low-build 29–32ms gaps are fixed; those remain an engine/input/ScrollActivity cadence hypothesis if the outlier event proves raw ScrollUpdate delivery is already sparse.
