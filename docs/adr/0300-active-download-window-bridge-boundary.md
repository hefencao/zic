# ADR 0300: Active download-window bridge boundary

## Status
Accepted.

## Context
The dev.320 01:31 high-refresh trace closes several broader explanations for the remaining fixed-position micro-jitter. Android Choreographer, non-zero ScrollUpdate and Flutter post-frame scene motion are predominantly ~8.3ms, while every `verticalSceneMotionSummary` reports zero layout-residual drift. Two reverse-geometry prefix rebases occur only while previously unknown lower-index dimensions are first adopted and therefore cannot explain the later repeated oscillation around pages 12-14.

After geometry is stable, each accepted read-direction reversal performs the same asymmetric 7/3 transport-window flip. There are 13 active direction flips in the trace; all 13 reconcile as `downloadAdded=5/downloadRemoved=5/downloadChanged=6`. Their reconcile median is 7.455ms and max is 9.669ms, against an 8.333ms 120Hz frame budget. The same flips also migrate two decode and two upload roles and repeatedly re-project already-resident static outputs. Framework Build/Layout/Paint/raster may remain cheap because this control work runs between framework phases.

The old dev.316 four-page direction hysteresis is not the right repair: it postpones the same large transaction and had already failed to explain the broader low-device jank before dev.317 moved observation drain out of the microtask queue.

## Decision
Keep the canonical desired Reader window unchanged at encoded forward7/back3 and decode forward2/back1. Keep the existing two-committed-page read-direction predictor, immediate current/visible/transition semantics, dev.317 ordinary-event-turn drain, and existing upload/native-texture behavior.

During vertical dragging/scrolling/settling only, insert an encoded-download bridge between the canonical guarded desired plan and the physical accepted plan:

1. Every download required by the new desired decode/upload set, plus current/transition transport, is mandatory and enters immediately without a migration quota.
2. Desired download identities already present in the previous accepted plan are retained; encoded-only scheduling metadata may remain at its previous role/priority while it is non-mandatory.
3. At most one new encoded-only desired identity is admitted for each newly committed current page.
4. Remaining capacity, bounded by the canonical desired download count, is filled by previous speculative identities rather than detaching them only because 7/3 orientation flipped.
5. Any remaining slot may be filled from desired identities. The bridge never exceeds the guarded download count and every DecodeId/UploadDemand must still have its DownloadId present.
6. At idle/scrub/jump boundaries the bridge is inactive and the accepted plan converges fully to the canonical desired window.

The bridge changes only active physical encoded-download membership. Decode/upload role selection, static presentation continuity, NetLane ownership/concurrency, geometry, ScrollPhysics and renderer behavior are unchanged.

## Consequences
A direction flip should no longer generate a 5-add/5-remove far-transport transaction. Normal sustained motion still advances speculative encoded coverage one slot per committed page, while immediate decode/upload sources remain available. The next device trace must use the bridge telemetry and reconcile cardinalities to falsify this mechanism directly. If full-window download churn collapses but the same fixed-position jitter remains, do not tune the migration quota or direction threshold; the next independent candidate is the retained-static projection continuity boundary that currently causes direction-flip resident re-presentation.

## dev.322 implementation correction
The first dev.321 device run did not validly test this decision. `missingDesired` was materialized with `toList(growable: false)` but the one-slot advance branch called `removeAt(0)`, producing 6,463 reconcile failures in the 02:50 trace and starving page demands. dev.322 preserves this ADR's bridge semantics but makes selection non-mutating (`first` plus a start index for the remaining fill). Any bridge trace with `taskFailed` is invalid for performance attribution.

## dev.323 device result
The corrected dev.322 03:35 run validly exercises this bridge with all pages loading and `taskFailed=0`. Across 26 active direction flips, `big_5x5=0`, download add/remove medians are 1/1, and reconcile median/max are 4.617/5.874ms. The transport objective is therefore achieved, but the user still reports the same fixed-position hitch. Keep this bridge as a bounded transport-control optimization; do not tune its quota or direction threshold as the remaining jitter repair. ADR 0301 owns the next independent retained-static re-projection boundary.
