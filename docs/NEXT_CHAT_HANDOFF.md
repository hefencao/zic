# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.80_streaming-raster-trace-export.zip`

Do not merge dev.65–79 candidates, overlays or remembered source trees. Mihon
and VibeVenera references remain read-only. The user-provided libwebp 1.6.0
archive is validation input only.

## Completed in dev.80

- Added monotonic ingress source revisions and per-DecodeId consumed-revision
  tracking. Same-key follow work drains source growth/seal changes that arrive
  during an active decode and exits without repeating an already-consumed latest
  revision.
- Unknown Content-Length transfer is projected as connecting until committed
  bytes advance, then receiving with real received-byte count. No fake percent.
- Added one `AlignedRasterSize` contract for static images, DecodeTarget and
  native WebP: contain, source aspect, integer comparison and paired 8-pixel
  physical alignment. Dart and Rust share fixture vectors.
- `MediaAspectViewport` is the only fit decision. Unknown intrinsic dimensions
  keep requested contain/fitWidth instead of filling the viewport; authoritative
  header/static dimensions are not replaced by aligned output-buffer dimensions.
  WebP prefix reads drain lengths received while a read is active.
- Android raw JSONL export uses an App-owned SAF `CreateDocument` channel.
  Debug Presentation only calls injected capabilities. Clipboard copy is a
  separate 64 KiB UTF-8 raw projection and reports truncation/failure.
- Added ADR 0064, dev.80 audit/static gate and owner tests. +7/-3, +2/-1,
  current/transition and 5/3/2 remain unchanged.

## Device/toolchain validation still required

1. Run `flutter analyze`, all Dart/Flutter package and App tests, Rust tests, then
   Android debug/release or at least kernel snapshot.
2. Use a large animated WebP whose first complete frame arrives before download
   completion. It must leave page loading while transfer remains active and keep
   advancing as later source revisions arrive.
3. Compare wide, tall and near-square JPEG/PNG/GIF/WebP pages in paged and
   continuous fitWidth modes across multiple DPRs. No format may stretch to the
   viewport; output raster dimensions should be 8-pixel aligned.
4. Copy a large raw trace and confirm the UI reports the bounded copied count.
   Export the full raw filtered trace through Android's document picker and
   verify the resulting JSONL opens after app background/foreground.
5. Re-run long-lived Venera, custom-locator cover cache, continuous-scroll and
   adaptive-animation checks from dev.79.

## Rejected regressions

Do not wait for full download before decode, restore Presentation-owned source or
cursor, add format-specific fit rules, independently resize X/Y, use `BoxFit.fill`
as a viewport fallback, invent unknown-length percentages, call Android
`file_selector.getSavePath()`, export the coalesced UI ring, or reduce preload and
lane settings.
