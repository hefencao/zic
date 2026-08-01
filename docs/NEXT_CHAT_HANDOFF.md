# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.75_compile-contract-ownership.zip`

Do not merge dev.65–74 candidates or overlays.

## Completed in dev.75

- Closed all compile errors reported after dev.74.
- Removed the unused `ComicDetailsScreen` compatibility wrapper and obsolete AssetBundleTransport App/Reader facades.
- Moved AssetBundleTransport tests to `pipeline_runtime`; downloads retains canonical page identity tests.
- Corrected explicit extension/domain imports and the invalid const Coverage call.
- Added compile/ownership regression gates and restored analyze/test coverage for pipeline_runtime, reader_runtime and local_media_ui.
- Added `docs/AI_ITERATION_PROMPT.md` for future Architecture/coupling-safe iterations.
- Kept Pipeline preload, decode/upload lanes, source transport, cover cache and Debug Trace behavior unchanged.

## Next validation

1. Run `flutter analyze`, all affected package tests, App tests and Android kernel/release build.
2. Verify the reported compile errors no longer occur in the user's Flutter environment.
3. Continue device validation of vertical geometry, cover warm cache and Debug Trace export/filter behavior.
4. Use `docs/AI_ITERATION_PROMPT.md` when opening a new chat.
