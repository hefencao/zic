# ADR 0301: Retained static re-projection boundary

## Status
Accepted.

## Context
The 03:35 dev.322 run is valid: all pages load, `taskFailed=0`, and the active download bridge removes every full 5/5 direction-flip transport migration. Across 26 active direction flips, download add/remove medians are 1/1 and reconcile median/max are 4.617/5.874ms, below the 8.333ms 120Hz budget, yet the same fixed-position hitch remains. The bridge is therefore insufficient as the remaining jitter root and its quota must not be tuned further.

The same trace exposes a narrower repeated presentation transaction. Every one of the 26 direction flips is followed within 15ms by exactly two authoritative-static presentations whose `framePipelineTiming.platformResidentReuse` is true. Their combined `presentMicros` median is 1.886ms and max is 4.785ms. AndroidTextureLease performs no blit, resize, schedule or platform call in this resident-key fast path; nevertheless Pipeline still crosses claim/present/timing/telemetry/snapshot bookkeeping because the page projection claim was cleared outside the current±2 continuity envelope and later reacquired.

## Decision
Keep the dev.321/dev.322 active download bridge, canonical 7/3 desired window, decode 2/1, current±2 presentation continuity, native texture ownership, dev.317 ordinary-event-turn observation drain and all existing Reader geometry/physics semantics.

UploadSession owns whether a claimed retained output is safe to re-project without another presentation call. `reusePresentedStatic` may return true only when:

1. the claim still references the UploadSession's exact current OutputFrame and has not been released;
2. decoder animation truth is complete and frameCount <= 1;
3. frame duration is zero; and
4. an OutputFrameTiming presentation has already completed for that exact OutputFrame.

When true, PipelinePageOutputStream keeps the new PresentClaim for lifetime/budget ownership and directly projects `claim.frame`; it does not call `OutputFrame.present()` again. First presentation, a never-presented static frame, animated output, changed identity/generation/frame, released output and fallback replacement continue through the normal presentation path. The optimization does not widen presentation continuity or keepAlive and does not create decode/upload/download work.

## Consequences
A direction/role re-entry of an already-resident static texture should no longer emit a new `framePresented`/resident-reuse timing transaction merely to reconstruct the Flutter surface projection. The next device trace must first remain fully loaded with `taskFailed=0`; then `tool/analyze_resident_static_reprojection_jank.py` should show resident-static representations near flips collapsing from the dev.322 baseline of 26/26 flips × 2. If those transactions disappear and the same hitch remains, do not widen the continuity envelope or re-present threshold; move below Pipeline projection to actual Flutter external-texture composition/presentation.
