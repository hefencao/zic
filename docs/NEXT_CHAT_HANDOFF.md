# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.74_vertical-geometry-artwork-trace.zip`

Do not merge dev.65–73 candidates or overlays.

## Completed in dev.74

- Fixed `local_media_ui.dart` directive-order compilation failure and added an all-Dart directive gate.
- Corrected runtime page ratio to height/width, removed negative stitch overlap, and made the continuous list directly positionable at a distant saved page.
- Unified source-browser/detail artwork with durable file-backed cache presentation and rejected non-image cache entries.
- Added Debug Trace coalescing, keyword/session/severity filtering, severity accents, and JSONL export; Mihon/Venera opaque identities are summarized.
- Kept Pipeline download/decode/upload ownership and 7/3, 2/1, 5/3/2 policy unchanged.

## Next validation

1. Run `flutter analyze`, targeted Reader/App tests, and Android release build.
2. On device, restore a chapter near page 87 and confirm no prefix mount burst or scroll reset.
3. Check stitched pages at multiple DPR values and source-provided/runtime-measured dimensions.
4. Reopen source/details pages and verify cover warm hits do not trigger network reloads.
5. Export filtered Debug Trace JSONL and inspect error-only output.
