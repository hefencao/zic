# dev.323 retained static re-projection audit

## Input
Device trace: `zic-debug-trace-2026-08-20T03-35-56.jsonl`. User observation: all pages load again, but fast scrolling still hitches at repeatable positions.

## dev.321/322 bridge result
The run is valid (`taskFailed=0`). `tool/analyze_direction_flip_120hz_jank.py` reports 26 active direction flips, `big_5x5=0`, median download add/remove 1/1, changed median 5, and reconcile median/max 4.617/5.874ms. The bridge therefore removes the full 5/5 transport flip and moves reconcile below a 120Hz budget, but the visible fixed-position symptom remains. The route is retained as a bounded transport-control optimization, not promoted as the remaining root cause.

## Repeated resident presentation
`tool/analyze_resident_static_reprojection_jank.py` reports:

```text
events=3235 active_direction_flips=26 task_failed=0
resident_static_represent=total=64 associated=52 flip_exactly_two=26/26 per_flip_median=2
resident_static_present_cost=per_flip_median_us=1886 per_flip_max_us=4785 window_us=15000 budget_120hz_us=8333
flip_pages=14:10,12:7,13:5,15:2,16:1,17:1
verdict=direction-flip-resident-static-representation
```

Every flip therefore repeats two presentations of already-resident authoritative static outputs. Their platform timing has `residentReuse=true`, zero blit, zero Surface reconfiguration and zero platform upload. Source inspection shows why: UploadSession retains the OutputFrame/texture after UploadDemand detach, but PipelinePageOutputStream may clear its projection claim outside the current±2 continuity envelope. Re-entry obtains a new claim and calls `present()` even though AndroidTextureLease already owns the same resident key.

## dev.323 intervention
Add owner-side `UploadSession.reusePresentedStatic(PresentClaim)`. It only accepts the exact current, unreleased, zero-duration, authoritative one-frame output after that OutputFrame has a non-null prior presentation timing. PipelinePageOutputStream then re-projects the claimed frame without another `present()` call. This does not extend the retention envelope; it only removes redundant presentation work after a retained frame returns to a presentation role.

## Falsification rule
The next run must keep all pages loaded and `taskFailed=0`. Success of the mechanism requires flip-associated resident-static `framePresented` timing transactions to collapse from 52/26 flips to near zero. If they collapse but the same fixed-position hitch remains, mark this route insufficient and move to final external-texture composition/present observation rather than widening current±2, changing keepAlive, or tuning bridge/direction thresholds.
