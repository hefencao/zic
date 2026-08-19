# dev.317 observation event-turn jank audit

## Device evidence
Input: `zic-debug-trace-2026-08-19T14-39-57.jsonl` from the user's low-performance reproduction device.

- dev.316 reduced 5-add/5-remove direction-flip reconciles to 7 from 20 in the previous stable trace, but visible UI jank remained. The dev.316 direction-hysteresis hypothesis is therefore falsified under its preregistered stop condition.
- The trace contains 84 non-summary `readerFrameTiming` samples. 66 have `frameIntervalMicros >= 20000`; 55/66 have both `buildMicros < 3000` and `rasterMicros < 3000`; 3/66 have both below 1000us.
- There are 100 `scrollCadenceOutlier` and 78 `platformFrameCadenceOutlier` events. These counts are observational and are not used as policy input.

The important shape is not a single expensive build/layout/paint phase: many long frame intervals occur between individually cheap Flutter framework frames.

## Source audit
`PipelineReaderSession.enqueueObservation` is latest-wins and does not synchronously reconcile inside Reader navigation. Before dev.317, however, `_scheduleObservationDrain` used `scheduleMicrotask`, and `_drainObservation` subsequently calls `accept`, plan/reconcile and lane work on the same Dart UI isolate. Existing dev.219/dev.302/dev.304 governance already documents this ownership; the new device evidence makes queue priority a testable boundary rather than a frozen implementation detail.

## dev.317 experiment
- Roll back dev.316's four-page direction hysteresis to the dev.313 two-committed-page predictor.
- Change only Reader observation drain from `scheduleMicrotask` to zero-delay `Timer.run` ordinary event scheduling.
- Preserve latest-wins semantics and immediate current/visible/transition UI state.
- Preserve 7/3 encoded demand, decode 2/1, NetLane, geometry, ScrollPhysics, native texture presentation and dev.313 local-static pre-presentation.
- Do not add the VibeVenera 180ms control debounce.

## Next measurement
Run `python3 tool/analyze_frame_between_control_jank.py TRACE`. The primary outcome is the count/share of >=20ms Reader frame intervals whose build and raster are both below 3ms. If that low-phase share does not materially fall while the visible symptom remains, close this route rather than changing timer thresholds.
