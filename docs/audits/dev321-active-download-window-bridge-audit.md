# dev.321 active download-window bridge audit

## Input
Device trace: `zic-debug-trace-2026-08-20T01-31-20.jsonl`. User observation: fast scrolling still produces visible jitter at repeatable positions.

## Closed or downgraded explanations
- Flutter scene motion is not generally stalling: all 17 `verticalSceneMotionSummary` records have `residualOutlierCount=0` and `maxAbsLayoutResidualDeltaPx=0.0`; most post-frame intervals are <10ms.
- Two large `expectedStart` rebases are real reverse-geometry adoption events, but they occur only during initial lower-index dimension resolution. They do not recur during the later repeated page12-14 oscillation and therefore cannot own the repeated symptom.
- The repeated resident static presentations have `residentReuse=true` and no physical blit/reconfigure, so the old RGBA copy hypothesis remains downgraded.

## Repeating fixed-position transaction
`tool/analyze_direction_flip_120hz_jank.py` on the dev.320 trace reports:

```text
events=1968 policies=129 active_direction_flips=13
flip_download_churn=big_5x5=13 added_median=5 removed_median=5 changed_median=6
flip_reconcile=count=13 median_us=7455 max_us=9669 budget_120hz_us=8333
flip_pages=12:6,14:4,13:2,15:1
download_bridge=events=0 retained_total=0 deferred_desired_total=0
verdict=active-direction-flip-full-window-churn
```

After the initial geometry settles, repeated `13 -> 12` and `13 -> 14` direction confirmations produce the same 5/5 transport flip. Representative `13 -> 12` reconcile costs are 9.669ms, 7.034ms, 7.547ms, 7.455ms, 7.299ms and 8.218ms. Representative `13 -> 14` costs are 8.692ms, 8.006ms, 6.946ms and 7.820ms. At 120Hz an 8.333ms budget means this control transaction can miss one display opportunity while Flutter Build/Layout/Paint/raster remain individually small; the historical >=20ms cadence-outlier threshold would not report a single 120Hz missed frame.

The same flips migrate two decode/two upload demands and re-present retained static pairs (for example pages10+11 or 15+16) without new blits. dev.321 intentionally does not change that second boundary yet, so the transport bridge remains a single conceptual experiment.

## dev.321 intervention
Canonical 7/3 desired policy and 2/1 decode policy remain unchanged. During active vertical motion only, mandatory foreground/near encoded sources are immediate; encoded-only desired membership advances at most one new identity per committed current page, while old speculative identities temporarily fill unused capacity. Idle converges fully to canonical 7/3. New policy trace fields are `downloadBridgeActive`, `downloadBridgeLocalMovement`, `downloadBridgeRetained`, `downloadBridgeDeferredDesired`, `downloadBridgeDesiredAdvanced`, `downloadBridgeSchedulingRetained` and `desiredDownloads`.

## Device falsification rule
Success requires the next trace to show full 5/5 direction-flip transport churn collapsing (preferably to <=1 speculative add/remove beyond mandatory source needs) and flip reconcile cost moving materially below the 8.333ms 120Hz budget, together with a visible reduction of the same fixed-position jitter. If 5/5 churn collapses but the symptom remains, mark this route insufficient and move to an independent active static-presentation continuity experiment; do not raise the direction hysteresis or add a time debounce.
