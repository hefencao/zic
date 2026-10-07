# ADR 0296: Reader observation ordinary-event-turn boundary

## Status
Accepted as the dev.317 single-variable device experiment. dev.316 prefetch-direction hysteresis is falsified and rolled back.

## Context
The dev.316 device run reduced the previously observed 5-add/5-remove asymmetric working-set flips from 20 to 7 without removing visible UI jank. The same 14:39 trace contains 84 non-summary `readerFrameTiming` samples; 66 have a frame interval of at least 20ms, and 55 of those have both build and raster below 3ms. This makes framework Build/Layout/Paint cost an insufficient explanation for most observed interval misses.

Reader navigation already publishes viewport/current state independently from Pipeline reconciliation, but `PipelineReaderSession.enqueueObservation` drained its latest-wins queue with `scheduleMicrotask`. Plan/reconcile/lane-pump work therefore remained on the Dart UI isolate with microtask priority immediately after the frame-producing callback.

## Decision
Keep latest-wins observation coalescing, control-no-op filtering, decode-target dirtiness, current/visible/transition state and all resource windows unchanged. Replace only the observation-drain scheduling call with `Timer.run`, yielding to the ordinary event queue before executing the same `_drainObservation` transaction.

This is not a 180ms debounce and adds no fixed time interval. It does not move Pipeline work to another isolate and does not claim that every timer runs after a vsync. It only removes microtask priority from this Reader observation edge. Source-kind, decode-refill and animation-resolution callback microtasks remain unchanged so the device experiment has one scheduling variable.

## Falsification
If the next comparable device trace still shows a similar rate of >=20ms frame intervals whose build/raster remain cheap, this route is falsified. Do not tune timer duration. Investigate untraced UI-isolate GC/allocation, platform-channel/native callbacks, texture/compositor synchronization and engine frame scheduling instead.
