# ADR 0302: Current-role satisfied-static scheduler boundary

Status: Provisional

## Context

The user-local fixed-position hitch is visually aligned with a neighboring page entering the current region. In the 05:33 trace, 36 `pageCurrent` transitions have a 3.895ms median Pipeline reconcile versus 0.688ms for the other 80 reconciles. Current promotion changes decode/upload roles even when the exact static frame is already decoded, uploaded and resident.

`LiveCoordinator` previously submitted/followed every added/changed decode and upload demand. Static sufficiency was discovered only after the lane task started, so role-only migration still pumped DecodeLane/UploadLane on the Dart UI isolate.

## Decision

Treat an already-satisfied exact authoritative static resource as scheduler metadata during role/priority migration. Decode may bypass lane follow only when there is no pending source revision and `_decodeNeedsFill` proves the existing decode plus prepared output already satisfies the demand. Upload may adopt the new demand role/revision in place only when the exact retained static output is alive, its decode holder has no successor, there is no decode failure/dispose, and no prepare is in flight.

Do not change current-index geometry, hysteresis, windows, artifact-pressure policy, presentation lifetime, animation handling, generation ownership or recovery paths.

## Validation

The next device trace must show lower `pageCurrent`-associated reconcile cost and fewer `uploadStarted` events before this boundary is accepted as a jitter fix. If those collapse but the hitch remains, inspect startup artifact-pressure hold/release separately.
