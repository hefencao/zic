# dev.325 current-role satisfied-static scheduler audit

## Device evidence reused

The 2026-08-20 05:33 DebugTrace is valid (`taskFailed=0`). `tool/analyze_current_role_boundary_jank.py` reports 36 current-boundary reconciles with median 3.895ms, max 5.838ms and 32/36 at least 3ms. The other 80 reconciles have median 0.687ms and only 2/80 at least 3ms. The 36 matched switches occur at preceding `pageTransition.currentCoverage` median 0.507 (range 0.501–0.526), so the user's three-zone description localizes the right promotion seam even though the implementation changes current near equal two-page coverage rather than a literal one-third threshold. Typical current promotion changes download 1/4/1, decode 1/3/1 and upload 1/3/1; 76 `uploadStarted` events fall in those boundary windows, median two per boundary.

This is materially stronger than a generic fixed-position correlation: `pageCurrent` is the discrete control identity that defeats the continuous-observation no-op filter and causes full plan reconciliation.

## Source audit

- `ReaderVerticalGeometry.positionAt()` chooses current from the viewport center, so the user's previous/current/next thirds are an approximate visual description of the center-crossing promotion boundary, not a literal one-third threshold.
- `_reconcileDecodes()` used to follow every changed demand and submit every added demand; `_decodeNeedsFill()` often rejected already-satisfied static work only after lane execution began.
- `_reconcileUploads()` used to submit/follow every non-last demand. `UploadSession.prepare()` can then discover an empty holder with an existing static output and return ready without producing another frame.
- Lane pumps occur when the atomic reconcile batches unwind, so these no-op tasks still consume the same UI-isolate control transaction measured by `pipelineReconcileTiming`.

## dev.325 boundary

Decode skips enqueue only when no source revision is pending and the exact existing DecodeSession is already satisfied. Upload adopts a retained/ready one-frame static output in place only under strict no-successor/no-failure/no-in-flight-prepare guards. No current-index, retention, decode window, bridge, presentation or artifact-pressure policy changes are included.

## Device acceptance

Re-run the same fixed boundary. Require `task_failed=0`, normal loading, `big_5x5=0` and resident-static re-present near zero. The direct mechanism target is a substantial drop from the 3.895ms current-boundary reconcile median and a substantial reduction from median two boundary `uploadStarted` events. Visible hitch relief determines whether this is a sufficient root or merely another bounded component.
