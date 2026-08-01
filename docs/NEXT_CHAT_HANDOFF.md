# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.76_reader-page-loading-ownership.zip`

Do not merge dev.65–75 candidates, overlays or remembered source trees.

## Completed in dev.76

- Audited the attached immediate-exit trace and found no exception, post-exit receiving or Reader-owned session leak.
- Removed the Reader viewport loading overlay and its duplicate page-ready state.
- Removed the `LocalImagePlayer.showLoadingIndicator` compatibility switch; page media owns visible loading/ready/invalid feedback.
- Kept first-frame telemetry in `_ReaderPageHost` without using it as a visual-state authority.
- Audited all remaining progress indicators and retained only owner-local route/content/command indicators.
- Added owner-package Widget regressions, Reader no-overlay regression, static gate, ADR 0060 and the dev.76 three-list audit.
- Kept Pipeline 7/3 download, 2/1 decode, current/transition upload, 5/3/2 lanes, GET/HEAD, plugin and cache behavior unchanged.
- Recorded an existing boundary debt instead of hiding it: `PipelinePageStream.source` still feeds Presentation-owned native cursor/texture decode. Closing it requires an atomic production uploader/output capability migration; this patch does not add a competing path.

## Next validation

1. Run `flutter analyze`, affected package tests, App tests and Android debug/release build in an SDK-equipped environment.
2. On Android, enter a vertical stitched Reader and confirm exactly one spinner follows the loading image area; no fixed viewport-center spinner may remain.
3. Repeat immediate route exit while the current WebP is decoding; confirm demand detach, no late UI callbacks/exceptions, and no post-exit receiving.
4. Inspect the current-page WebP partial/full decode sequence and first-frame telemetry before changing Pipeline policy.
5. Close the encoded-source/decode/upload boundary only as an atomic `pipeline_runtime` capability: production `FrameUploader`, presentation-safe output projection, then removal of `PipelinePageStream.source` and Presentation-owned cursor/texture lifecycle.
