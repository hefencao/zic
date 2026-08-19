# ADR 0295: Prefetch direction hysteresis boundary

## Status
Accepted for dev.316 device falsification.

## Context
The user reports repeatable jitter at the same scroll positions, while VibeVenera DevTools stays roughly 3-8ms without recurring ~20ms UI jank. Reconstructing dev.314 FrameTiming batches onto Reader monotonic time shows that the strongest repeatable ZIC UI-build spikes coincide with orientation changes of the asymmetric 7/3 prefetch working set. A flip changes five encoded identities on each side at once (`downloadAdded=5`, `downloadRemoved=5`) and migrates most surviving priorities. The 20 such transactions have 7.425ms median reconcile; other reconciles have 1.289ms median. Nine of sixteen `buildMicros>=10000` frames are within 15ms of a 5/5 flip, with 14.617ms median build near flips versus 1.637ms away.

The viewport itself must remain immediate. The problem under test is that short reverse traversal is being promoted too quickly into a long-horizon prefetch-direction reversal.

## Decision
`BrowsingDirectionPredictor` owns only prefetch orientation. Opposite committed-page distance accumulates and flips the 7/3 orientation only after four pages. Movement in the existing direction clears the candidate; scrub/jump/large discontinuity also clears it. Reader current page, target, visible coverages, ScrollPosition and transition ownership are not delayed. The 7/3 encoded and 2/1 decode window sizes do not change.

## Rollbacks
- dev.314 hidden-static active-scroll suppression is rolled back to dev.313 behavior because the device trace still reproduced and moved first copy toward transition.
- dev.315 static encoded Flutter presentation is rolled back because the original jitter remained and 378 reconcile attempts violated the mandatory-current-per-lane plan invariant.
- No 180ms debounce is added.

## Falsification
Repeat the same back-and-forth path. The next trace should show materially fewer 5/5 `pipelineReconcileTiming` transactions and fewer 14-20ms build spikes. If those transactions collapse but visible jank does not, close this route and inspect the remaining non-flip heavy-build frames; do not keep increasing hysteresis.
