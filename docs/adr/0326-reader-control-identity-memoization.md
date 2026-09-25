# ADR 0326: Reader control identity memoization

## Status

Accepted

## Context

Vertical continuous Reader motion crosses discrete page/control boundaries while
keeping a bounded 7/3 encoded working set plus decode/upload intents. The
scheduling policy is intentionally recomputed only when that discrete control
state changes, but Profile evidence showed that the recomputation still spent a
large fraction of the UI-isolate budget repeatedly deriving immutable resource
identities.

In the pre-change Profile sample (`reader-cpu-profile-summary.txt`, 6,842
samples over about 8.95 seconds), `PipelineController._replan` was present in
1,080 samples (15.8%) and `PipelineReaderSession.accept` in 1,215 (17.8%).
`DownloadId.key` alone was present in 475 samples (6.9%), while
`_OneByteString.hashCode` accounted for 368 exclusive samples (5.4%). A VM
timeline from the same investigation measured Reader observation drains at a
2.919ms median and 8.210ms maximum; 9 of 11 UI frame-start gaps of at least
12ms overlapped those drains.

The downstream scheduler was not the dominant cost. Active-motion
`pipelineReconcileTiming` was normally below 2.5ms. Geometry residual,
retained-static presentation, renderer topology and the existing Pipeline
window had separately been checked, so shrinking prefetch, changing
ScrollPhysics or adding Reader-side interpolation would have attacked the wrong
owner.

## Decision

`DownloadId` and `DecodeId` remain immutable value identities, but their pure
`key`, `legacyKey` and structural `hashCode` projections are memoized per
instance. `DownloadId` is no longer a const constructor so those lazy derived
facts can be retained. Repository search found no const `DownloadId`
construction sites, and serialized key formats, equality, hashing semantics and
`pageIndexHint` exclusion are unchanged.

The memoization belongs in `domain` because the repeated work is a property of
the immutable identity itself. Reader, Pipeline, LiveCoordinator and NetLane
must not grow private identity caches or alternate keys for this optimization.
The change does not alter 7/3 encoded coverage, decode/upload windows, priority,
preemption, geometry, touch resampling, ScrollPhysics or presentation
ownership.

A focused regression asserts that repeated hot key projections return the same
memoized String instance while the existing identity/equality/JSON tests remain
authoritative for semantic compatibility.

## Device evidence

With the memoization enabled, the matched Profile run (`reader-cpu-profile-after-identity-cache.txt`,
11,146 samples over about 8.81 seconds) reduced:

- `PipelineController._replan` from 15.8% to 2.9% of samples;
- `PipelineReaderSession.accept` from 17.8% to 3.2%;
- `_OneByteString.hashCode` exclusive samples from 5.4% to 0.73%;
- repeated `DownloadId.key` work from about 6.9% to only first-use lazy
  initialization, about 0.31%.

A separate 4x ballistic diagnostic kept the existing test-only velocity
multiplier and Pipeline policy unchanged. The older effective window had 7
frame intervals with 16.478ms mean and 24.719ms maximum. After memoization,
steady ballistic windows contained 63, 29 and 113 intervals with means of
8.359ms, 9.054ms and 8.378ms; their maxima were 16.467ms, 16.491ms and
16.471ms, with no ballistic interval at or above 20ms.

The first finger-down window still contained a 24.935ms frame interval, but its
raw drag notification gap was already 30.756ms and it occurred before the first
page-boundary replan. That remains the separate input/direct-manipulation
boundary covered by ADR 0325; it is not a reason to move resource control into
Reader or tune ScrollPhysics.
