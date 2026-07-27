# media_core

Rust native media core for zic.

The encoded source remains an in-memory derivative of the authoritative Dart
artifact. Appending requires a matching epoch and exactly contiguous offsets.
Cursors retain shared source state, so freeing the source handle does not leave
an existing cursor with a dangling pointer; resetting the source still makes
that cursor stale.

## Animated WebP

The cursor uses libwebp's partial demux API on every decode attempt:

1. `WebPDemuxPartial` parses the currently committed prefix.
2. A frame is decoded only when `WebPIterator.complete` is true.
3. Incomplete frames return `ZIC_CURSOR_NEED_MORE_DATA` without advancing the
   cursor.
4. Complete frame fragments are decoded to RGBA, scaled to the physical decode
   target, and composed according to WebP blend/dispose semantics.
5. The frame index advances only after an immutable `zic_frame` is created.

The current cursor performs one pass through the available animation. Loop
count and playback repetition remain session-level follow-up work.

## Native dependency

Desktop builds use the system `libwebp` and `libwebpdemux` development
libraries. Custom and Android builds may provide prebuilt libraries with:

```bash
export ZIC_WEBP_LIB_DIR=/absolute/path/to/lib
export ZIC_WEBP_STATIC=1   # optional; defaults to dynamic linking
cargo build --manifest-path native/media_core/Cargo.toml --release
```

The Android packaging step must eventually place the resulting transitive
native libraries in the matching ABI directory. The Flutter app does not yet
load this core on Android by default.

Run the C-level dependency/fixture smoke check with:

```bash
./tool/check_webp.sh
```
