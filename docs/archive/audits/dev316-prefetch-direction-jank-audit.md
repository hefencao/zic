# dev.316 prefetch-direction jank audit

Evidence: stable dev.314 low-performance-device trace `zic-debug-trace-2026-08-19T11-45-04.jsonl`; dev.315 trace `zic-debug-trace-2026-08-19T13-13-21.jsonl` is used only to confirm its regression.

- dev.314: 264 `readerFrameTiming` samples. Raster p95 is about 3.1ms; repeated UI/build spikes reach 13-17ms with three >20ms outliers.
- 20 reconciles satisfy `downloadAdded=5 && downloadRemoved=5`: median 7.4255ms, max 10.284ms. Other reconciles: median 1.289ms.
- Reconstructed frame-vsync times show 9/16 frames with build>=10ms within +/-15ms of a 5/5 direction flip. Near-flip build median is 14.6175ms; away-from-flip median is 1.637ms.
- Replaying the observed committed-page sequence predicts 28/20/10/4/1 prefetch flips for reversal thresholds 1/2/3/4/5 respectively. Four pages is the smallest threshold that removes most local oscillation while still allowing a sustained reverse traversal to reorient the asymmetric 7/3 working set.
- dev.315: 378 `taskFailed` events report `Bad state: a plan must contain exactly one current demand per lane`; therefore dev.315 is not a valid production base and must be rolled back, not patched by weakening the invariant.

This audit does not claim every platform cadence miss is explained. dev.316 targets the correlated UI-isolate 5/5 working-set churn and leaves current/visible/transition presentation immediate.
