# Implementation Status

## 0.14.0-dev.14 — statically typed cursor outcomes and Android native packaging

### Cursor contract repair

`FrameCursor.decodeNext()` no longer returns nullable frames. `CursorStep`
separates a produced frame, an incremental wait, and terminal end-of-stream.
`CursorBinding` carries the mandatory frame cursor and an optional loop view.
`DecodeSession` stores that binding directly and no longer performs a runtime
`is LoopCursor` check or uses `null` to infer native state.

A non-loop cursor can now report a real terminal end. A looping cursor receives
rewind only after an explicit end step and an empty holder. Cancellation still
disposes a frame returned after the demand was superseded.

### Incremental decoder hardening

The libwebp C smoke test now parses every byte prefix of all three deterministic
fixtures and rejects false parse errors or complete frames without fragments.
The Rust ABI test appends the primary animation one byte at a time, drains only
real complete frames, and verifies that cursor indexes never advance on
`NeedMoreData`.

### Android native packaging

`tool/build_android_native.sh` builds `media_core` for arm64-v8a,
armeabi-v7a, and x86_64 using the Android NDK and per-ABI libwebp libraries. It
packages `libmedia_core.so` and shared libwebp dependencies into Flutter
`jniLibs`, or supports PIC static archives when requested.
`tool/check_android_native.sh` validates the produced layout. The split APK
script invokes native packaging whenever `ZIC_ANDROID_WEBP_ROOT` is configured.

### Next iteration

1. Add a Kotlin `SurfaceProducer` registry and a dedicated serial blit worker.
2. Pass retained native frame handles to Android through JNI without copying
   RGBA through MethodChannel.
3. Separate texture allocation from first blit and add lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

## 0.13.0-dev.13 — animation metadata and loop semantics

### Native cursor metadata

ABI v4 adds frame count, WebP play count, metadata completeness, zero-based
cycle, rewind, and frame-cycle accessors. The native decoder refreshes metadata
from every successful partial demux. Rewind is accepted only after a real
end-of-stream result. A play count of zero is infinite; a positive value limits
the total number of cycles. Rewind resets canvas composition and frame numbering
while retaining source ownership and epoch.

A deterministic `finite_loop.webp` fixture declares two frames and a play count
of two. Rust tests cover one allowed rewind and the final rejected rewind. The
C smoke test validates frame count and loop metadata independently through the
installed libwebp headers and library.

### Session loop ownership

The media contract now exposes `AnimationInfo` and the optional `LoopCursor`
capability. `DecodeSession` keeps non-looping fake/fallback cursors unchanged.
For a looping cursor, it rewinds only after EOF and only when the holder is
empty, so a deeper watermark cannot introduce duplicate frame indexes while an
older cycle is still retained. Infinite content continues with a new cycle;
finite content enters the explicit `DecodeState.ended` state once its play count
is exhausted.

Decode snapshots expose animation metadata and cycle. Every successful rewind
emits `animationLoop` telemetry.

### Next iteration

1. Add Android native build/package automation for arm64-v8a, armeabi-v7a, and
   x86_64, including libwebp dependencies.
2. Add a Kotlin `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to an Android texture uploader without sending
   RGBA bytes through MethodChannel.
4. Add lifecycle-safe texture retirement and background/foreground tests.

## 0.12.0-dev.12 — real incremental Animated WebP decode

### Native decoder

The existing ABI v3 cursor now performs real WebP work instead of returning
`unsupported`. It reparses the authoritative committed prefix with
`WebPDemuxPartial`, requests the next one-based frame, and only decodes when the
iterator marks that frame complete. A partial frame returns `needMoreData`
without mutating the canvas or advancing the frame index.

Complete frame fragments are decoded to straight RGBA with libwebp, scaled to
the physical `DecodeId` target, and composed onto a persistent target-size
canvas. Composition implements `WEBP_MUX_BLEND`, `WEBP_MUX_NO_BLEND`, and
previous-frame background disposal. The immutable composed canvas becomes the
retained native frame payload, with frame duration propagated in microseconds.

The decoder currently performs one pass. Session-level loop count and cursor
reset semantics remain explicit next work rather than being hidden in the
native cursor.

### Native dependency boundary

`build.rs` links `webpdemux` and `webp`. Desktop builds use system libraries;
custom/Android builds may set `ZIC_WEBP_LIB_DIR` and optionally
`ZIC_WEBP_STATIC=1`. The Flutter Android package does not yet bundle these
transitive native libraries.

A deterministic two-frame lossless Animated WebP fixture is checked into the
native test data. Rust tests validate partial-prefix waiting, real red/green
RGBA output, duration/size metadata, and end-of-stream. A C smoke program also
compiles and runs directly against the installed libwebp to validate the
headers, partial demux behavior, fixture metadata, and fragment decode.

### Next iteration

1. Add animation metadata and loop/repetition semantics to the cursor/session
   contract.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Package media-core and libwebp per Android ABI and connect a no-copy uploader.
4. Replace baseline software frame scaling with decoder-native scaling where
   platform profiling proves it beneficial.

## 0.11.0-dev.11 — explicit playback capability and native frame ABI

### Requested fix

`ReaderBinding` no longer derives a local `playback` variable from a value typed
as `Coordinator`. Its constructor now requires the demand and playback
capabilities separately:

```dart
required Coordinator coordinator,
required PlaybackCoordinator playback,
```

The binding stores `_coordinator` and `_playback` with their actual interface
types. The app and tests explicitly pass the same live/fake object when it
implements both contracts. A regression test also supplies two separate
objects, proving the binding does not depend on a runtime type check.

### Native cursor and frame ownership ABI

The Rust media core ABI is now version 3. `ByteSource` uses shared source state;
a cursor clones that state, so releasing the source handle cannot leave an
existing cursor with a dangling pointer. Source reset still advances the epoch,
and cursor decode rejects stale epochs.

Added stable C/Rust/Dart symbols for:

- cursor create/free/epoch/decode-next;
- frame retain/release;
- frame epoch/index/size/duration/format/length/data access.

A frame handle owns an `Arc` to immutable frame data. `retain` creates another
independent handle, and the data remains valid until the final handle is
released. Dart wraps this as `NativeCursor`, `NativeFrame`, and
`NativeCursorFactory`; copied byte access does not expose a long-lived raw
pointer to application code.

The ABI intentionally returns `unsupported` for sealed WebP decode until the
real WebP decoder is linked. It does not synthesize frames or advance cursor
state. Unknown/incomplete input returns `needMoreData`.

### Source failure status

Added `SourceStatus.failed` at ABI index 6 and mapped lock/native failures to a
structured source failure. `Ingress` disables only the derived native source;
the durable artifact remains authoritative.

### Tests and gates

- Added explicit demand/playback contract coverage for `ReaderBinding`.
- Added native cursor factory contract coverage and ABI enum/version checks.
- Added Rust tests for source/cursor shared ownership and retained frame handles.
- Repository validation now requires the explicit playback field and every new
  cursor/frame ABI symbol in Rust, C, and Dart.

### Next iteration

1. Link a real incremental Animated WebP decoder behind the cursor ABI.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to the Android uploader without copying through
   MethodChannel.
4. Resolve frame budgets from live device memory and thermal telemetry.

## 0.10.0-dev.10 — reader binding and frame budgets

### Requested fix

- Replaced `ReadingDirection.leftToRight` in
  `pipeline/test/viewport_phase_test.dart` with the canonical `ltr` enum value.
- Added a repository regression gate that rejects the stale long-form value.

### Reader runtime binding

Added `ReaderBinding` as the application composition boundary for one reader
session. A single `ReaderObs` now drives `PipelineController`, demand
reconciliation, `ViewportResolver`, and playback synchronization. The demo app
uses this binding instead of wiring only the demand callback.

`Coordinator` remains the demand contract. `PlaybackCoordinator` is a separate
capability implemented by both live and fake coordinators, so non-playback
coordinators do not need dummy methods.

### Decoded/output budgets

Added `FrameBudget` and `FrameBudgeter` with independent decoded and renderer
output byte limits. Each limit has a current-page reserve. Non-current sessions
may use only the remainder and are trimmed in ascending demand priority.
Current-page resources are not silently discarded when the current page alone
exceeds a limit.

`FrameHolder` can now trim by bytes while respecting active claims.
`UploadSession` exposes output bytes and only trims an output when no present
claim exists. `LiveCoordinator` enforces the budget after reconciliation,
decode completion, and upload completion, and emits `frameBudget` telemetry
when bytes are released.

### Next iteration

1. Add native cursor/frame ABI and frame-handle retain/release ownership.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Resolve frame budgets from device memory/thermal telemetry instead of fixed
   construction-time limits.

## 0.9.0-dev.9 — split APK and viewport playback gate

### Requested fixes

- Removed the two trailing commas inside `SourceStatus.values[...]` index
  expressions in `bridge/native_source.dart`.
- Android APK builds now go through `tool/build_android.sh` and always use
  `--split-per-abi`.
- CI builds split debug APKs instead of a single fat APK.

### Viewport playback integration

Added `ViewportResolver` and `ViewportState` with four phases:

- `idle`;
- `dominant`;
- `overlap`; and
- `continuous`.

For discrete PageView navigation, playback freezes only while both pages have a
significant overlap. It resumes as soon as either page becomes dominant. For
continuous/custom scrolling, presentation remains frozen until the interaction
returns to idle.

Added `PlaybackGate` and `LiveCoordinator.syncPlayback()`. The gate applies
freeze/resume changes only when state changes, freezes a running page before it
leaves the tracked viewport, and does not restart timers repeatedly for
identical viewport observations.

### Build and regression gates

- Added `tool/build_android.sh [debug|profile|release]`.
- Added `make android-apk`.
- `tool/check.sh --require-toolchains` now also builds split debug APKs.
- Repository validation checks split APK configuration, native source index
  syntax, viewport exports, and coordinator playback integration.

### Next iteration

1. Connect Reader viewport reports to `ViewportResolver` and the live pipeline
   binding used by the app.
2. Add decoded/output byte budgets with a reserved current-page allocation.
3. Implement native cursor/frame ABI and frame-handle ownership.
4. Add Android `SurfaceProducer` texture registry and serial blit worker.
