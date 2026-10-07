# ADR 0064: Unified raster contract and platform-owned Trace export

## Status

Accepted for `0.31.0-dev.80`. Supplements ADR 0061–0063.

## Context

The dev.77 media-runtime migration still left three interpretations distributed
across packages:

1. a growing encoded source could notify Decode while a same-key task was active,
   but there was no monotonic revision drain proving that the latest append would
   be consumed exactly once;
2. static images, complete-byte animation, Pipeline WebP output and native WebP
   independently selected aspect fit and decode dimensions, allowing unknown
   intrinsic dimensions to fall through to `BoxFit.fill` and allowing Dart/Rust
   raster choices to diverge;
3. the Debug page selected `file_selector.getSaveLocation` itself. Android did
   not implement that backend operation, and an oversized raw JSONL clipboard
   write could fail together with file export.

## Decision

- `IngressSnap.revision` is the monotonic encoded-source lifecycle revision.
  `DownloadSession` emits every growth/seal/failure revision. `LiveCoordinator`
  tracks the last consumed source revision per `DecodeId`; a same-key follow task
  drains revisions that arrive while decode is active and duplicate queued
  follows exit without repeating the latest revision.
- `pipeline.AlignedRasterSize` is the canonical physical raster contract:
  contain within source/viewport bounds, preserve aspect as closely as an
  aligned pair permits, use integer ratio comparison, and align both physical
  dimensions to 8 pixels. The native WebP implementation uses the same integer
  algorithm and shared fixture vectors.
- Original media dimensions and physical output buffer dimensions are distinct.
  `MediaAspectViewport` alone selects `contain`, `fitWidth` or `cover`. When
  intrinsic dimensions are known it fits one source-aspect box and child
  renderers fill only that box; while dimensions are unknown the child receives
  the requested fit directly. Output buffer dimensions cannot overwrite
  authoritative header/static dimensions.
- Android JSONL saving belongs to App platform composition and uses the Storage
  Access Framework `CreateDocument` contract over a dedicated MethodChannel.
  The Debug page only invokes an injected exporter. Clipboard copy is a separate
  bounded UTF-8 projection and reports its own failure.
- Unknown Content-Length is not converted to a fake percentage. Pipeline
  transfer projection distinguishes `connecting` from `receiving` using
  committed-byte growth and exposes received bytes.

## Consequences

- Ordinary images and WebP no longer have separate aspect/8-pixel policies.
- Streaming first-frame production does not wait for artifact seal merely
  because source updates arrived while a decode task was active.
- The Android export path no longer calls the unsupported
  `file_selector.getSavePath()` implementation.
- Copy can intentionally include fewer raw events than file export; the UI must
  state the copied count and truncation.
- The +7/-3 download window, +2/-1 predecode window, current/transition upload
  set and 5/3/2 lane capacities remain unchanged.

## Rejected alternatives

- Waiting for full download before decode.
- Per-format `BoxFit` or raster corrections, double stretching, crop/overlap, or
  independent X/Y resize.
- Fake progress percentages for responses without Content-Length.
- Restoring a Presentation-owned WebP cursor or decoder.
- Falling back from failed file export to the coalesced 500-event UI ring.
