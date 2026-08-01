# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.78_reader-output-replay-diagnostics.zip`

Do not merge dev.65–77 candidates, overlays or remembered source trees. Mihon and VibeVenera references remain read-only. The user-provided libwebp 1.6.0 archive is a validation/dependency source, not a ZIC source overlay.

## Completed in dev.78

- Closed the reported `RendererKind` import and `PlaybackState` registry compile gaps at their owning packages.
- Changed native WebP target dimensions from an exact stretch rectangle to no-upscale aspect-preserving maximum bounds; upload and Android textures use actual fitted frame dimensions.
- Added demand-detach replay: an empty WebP holder recreates its ended cursor when the page returns, while ordinary EOF/finite-loop semantics remain unchanged.
- Removed details-page all-chapter page-count body preflight, removed the target-manifest full-library reload, and moved durable read-state persistence off the synchronous Reader navigation path.
- Split Debug Trace into a small coalesced UI ring and a larger bounded raw export ring; copy/file export use raw events and file-save errors are visible.
- Added ADR 0062, dev.78 audit/static gate and owner regressions. Preserved +7/-3, +2/-1, current/transition and 5/3/2.

## Next validation

1. Run `flutter analyze`, all package tests including sessions/pipeline_native/local_media_ui/reader_runtime, and App Widget tests.
2. Build Android debug/release or at least kernel snapshot.
3. On Android, open representative wide, tall and small WebP pages and verify actual geometry is not stretched or cropped.
4. Scroll affected static/finite WebP pages out of the decode/upload window and back; they must replay a first frame without texture accumulation.
5. Measure chapter-tap-to-route and route-to-first-frame separately after removing page-count preflight.
6. Export a long Reader trace through Android's document provider; verify raw download/decode/upload/error context and raw-drop count.
