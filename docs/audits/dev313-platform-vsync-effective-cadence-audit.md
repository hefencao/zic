# dev.313 platform-vsync effective cadence audit

## Cross-device dev.312 evidence

The two user device traces are intentionally treated as different hardware classes rather than pooled.

### Low-performance device — 09:55:20

- API 36, display 120Hz.
- `displayHasArrSupport=false`.
- dev.312 ARR policy evidence: `applied=true`, `currentBalanced=false`.
- 18 `scrollCadenceOutlier`: 13 ballistic, 5 drag-driven.
- Ballistic gap median 26.080ms, p90 about 40.022ms, max 43.496ms.
- 26 `platformFrameCadenceOutlier`; 21 have `systemFrameGapMicros >= 20000`; median of those system gaps 25.678ms.
- Platform-outlier main-thread CPU-gap median 9.735ms; 10/26 have CPU/wall ratio below 35%.
- Healthy Flutter scrolling summaries cover 428 frames; representative `frameIntervalMicros` median is 16.478ms, with summary minima down to 16.254ms.

### High-performance device — 09:58:03

- API 36, display 120Hz.
- `displayHasArrSupport=true`.
- dev.312 ARR policy evidence: `applied=true`, `currentBalanced=false`.
- 46 `scrollCadenceOutlier`: 28 ballistic, 18 drag-driven.
- Ballistic gap median 28.606ms, p90 about 37.723ms, max 51.258ms.
- 40 `platformFrameCadenceOutlier`; 28 have `systemFrameGapMicros >= 20000`; median of those system gaps 27.944ms.
- Platform-outlier main-thread CPU-gap median 7.282ms; 20/40 have CPU/wall ratio below 35%.
- Healthy Flutter scrolling summaries cover 758 frames with representative median 16.124ms; dragging summaries cover 115 frames with median 16.144ms.
- A conspicuous subset of system-frame gaps is about 27-31ms while main-thread CPU is only about 2-3ms. Several such platform gaps precede matching ballistic cadence outliers by roughly 34-35ms on the shared monotonic axis.

The high-performance device therefore is not simply doing more synchronous work. Its baseline cadence is slightly tighter, while low-CPU pacing discontinuities are cleaner; a similar or slightly larger skipped interval can consequently be more visually obvious even if the total outlier rate is not higher.

## Closed / downgraded explanations

1. **ARR as common root: rejected.** The low-performance device has `displayHasArrSupport=false` and still reproduces. On the ARR-capable high-performance device the dev.312 policy was confirmed active yet the issue remains.
2. **Simple touch boost 120Hz -> post-lift 60Hz transition: not supported.** High-device dragging and ballistic/scrolling healthy Flutter timing are both already around 16.1ms on a 120Hz display.
3. **Simple CPU/GPU capacity starvation: strongly downgraded.** The stronger device can look worse and many of its platform gaps have very low main-thread CPU occupancy.
4. **dev.311 renderer topology: already falsified.** Flutter-image presentation did not collapse ballistic cadence and added substantial output preparation cost.

## Missing discriminator

The existing native probe discards normal intervals and therefore hides whether the Android app Choreographer itself is normally ~8.3ms or ~16.7ms. `readerFrameTiming` only establishes that Flutter-produced frames are ~16ms. dev.313 adds `platformFrameCadenceSummary`, a bounded native histogram over all Choreographer intervals, and removes active ARR behavior from production Reader so the next run measures the unmodified cadence boundary.

This probe is observation-only. No requested frame rate, touch-boost toggle, Window refresh intervention, forced frame, Ticker smoothing, ScrollPhysics tuning or position interpolation is introduced.
