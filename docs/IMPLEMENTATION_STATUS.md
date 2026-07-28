# Implementation Status

## Unreleased candidate from 0.18.3-dev.21 — crash-safe WebP entry and local folder switching

### Reader smoke timeout repair

The failing helper repeatedly issued zero-elapsed pumps while waiting for a widget
inside a route transition. Elapsed transition time never advanced, so the keyed
Reader media page remained offstage even though the destination route had been
pushed. Navigation coverage now stops at the keyed destination route with
`skipOffstage: false`. Reader media content is a separate test that injects a
one-page chapter manifest directly and synchronizes on `WebpPreviewState.ready`.
Catalog and static routes likewise use stable screen/entry keys rather than copy.

### Crash-safe WebP activation

Reader media, bundled WebP, local single-file import, and local-folder import all
start on `WebpPlayerEngine.flutter`. Reader and folder switching keep engine controls
hidden so their normal workflows cannot start FFI/texture. In standalone previews,
selecting `Native（实验）` opens an explicit confirmation dialog; cancellation leaves the
Flutter engine selected without native work. Native initialization and present
failures still emit attributed fallback telemetry and return to Flutter codec.

Android `SurfaceProducer.scheduleFrame()` is posted to the main handler rather
than called from the serial blit worker. Surface callbacks use
`onSurfaceAvailable`/`onSurfaceCleanup`; the blit lane retains the current frame
for redraw and releases it on replacement, resize, output release, or detach.

### Local WebP folder import

The app adds a directory picker contract and `PickedWebpFolder`. Directory contents
are recursively enumerated in a background isolate, filtered case-insensitively
for `.webp`, naturally path-sorted, and converted to explicit relative display
names independent of `XFile.name`. The folder screen keeps one current player and
provides previous, next, and lazy-on-open file selection controls. Cancellation,
empty folders, recursive ordering, route ownership, and file switching have
independent tests.

### Validation status

Repository constraints and available syntax/native stub checks pass in this
sandbox. Flutter, Dart, Rust/Cargo, Android SDK, and Android NDK are not installed
here, so the target Flutter tests and device/native gates must still be run in the
external toolchain environment. Version remains `0.18.3-dev.21`; this is an
unverified validation candidate, not a stable baseline.

## 0.18.3-dev.21 — unambiguous malformed-WebP error state

### Root cause

The malformed-file preview rendered two widgets containing `WebP 文件无效`: the primary validation detail and the footer status. `find.textContaining` therefore correctly returned two matches even though navigation, filename ownership, and validation were all working.

### Repair

The detailed validation message now owns `webpPreviewErrorKey`. The footer reports the broader state `加载失败`, while the test waits for and reads the keyed detail widget. Repository gates reject both a duplicated footer validation phrase and a return to page-wide text matching.

### Validation before the next chat

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.3-dev.21.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.2-dev.20 — explicit local-import display-name ownership

### Root cause

`XFile.fromData(..., name: ...)` does not provide a portable guarantee that the resulting `XFile.name` is non-empty in every Flutter test backend. The previous route synchronization repair reached the correct preview screen, but `WebpPlayerScreen.file` reconstructed its title from `file.name`, so the keyed title existed with an empty string.

### Repair

`WebpPicker` now returns `PickedWebp`, which owns both the `XFile` and its normalized `displayName`. Production system-picking derives the name from `XFile.name`, then the path basename, then `本地 WebP`. Tests inject the expected display names explicitly. `DemoHome` passes the owned name into `WebpPlayerScreen.file`, and the screen only falls back to file metadata when no explicit non-empty name is supplied.

The stable route/title keys and bounded pumping remain in place. This separates three concerns cleanly: asynchronous route synchronization, selected-file bytes, and user-facing naming.

### Validation before the next chat

Run at minimum:

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.2-dev.20.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.1-dev.19 — deterministic local-import route tests

### Picker route synchronization

The local picker is asynchronous and the material route transition is scheduled after the picker future completes. A single fixed-duration `pump` can end on the first route frame rather than after the destination is discoverable, so exact-title finders were timing-dependent. The preview now exposes stable screen and title keys, and the widget tests use a bounded frame pump until the destination marker appears.

Malformed imports use the same route marker, then independently wait for the controlled `WebP 文件无效` state. This preserves the product behavior while removing dependence on animation timing and codec scheduling.

### Next chat

Continue from `zic_v0.18.1-dev.19.zip` only. The next engineering target remains Android `SurfaceProducer` texture presentation, followed by runtime telemetry and real reader-page integration.

## 0.18.0-dev.18 — validated local import and source-aware raster quality

### Local import stability

The picker route test now injects the real finite-loop WebP asset rather than a twelve-byte RIFF signature. `WebpInfo` validates complete RIFF length and reads VP8X, VP8, or VP8L canvas dimensions before the preview creates a Flutter or native codec. Malformed imports remain on the preview route and show a controlled error instead of feeding invalid bytes into the image pipeline.

### Decode raster versus display target

`DecodeTarget` remains the DPR-aware, eight-pixel-aligned physical display target. The new `RasterPlan` derives the actual encoded-image decode dimensions. Large images are downsampled to the bounded display target, while sources smaller than the viewport remain at intrinsic dimensions. This prevents animated codecs from interpolating tiny partial subframes before composition and avoids allocating multi-megapixel buffers for four-pixel fixtures.

Both native `RawImage` and Flutter `Image.memory` use nearest-neighbour rendering only for very small sources enlarged by at least 2x. Normal comic pages retain medium filtering. Native cursor identity follows the decode raster, so viewport-only display changes no longer recreate a cursor when the decoded pixel dimensions remain unchanged.

### Next iteration

1. Move native RGBA presentation to Android `SurfaceProducer` texture output.
2. Add device telemetry for decode raster, display scale, frame preparation, and present deadlines.
3. Connect the source-aware raster plan to real reader page decode sessions.
4. Add local chapter/CBZ import with persisted catalog metadata.

## 0.17.0-dev.17 — adaptive physical targets and deadline-based WebP playback

### Compile and target repair

`static_demo.dart` now imports the pipeline contract that owns `DecodeTarget`. The target itself has moved into a dedicated pure-Dart module. `DecodeTarget.viewport` converts logical viewport dimensions through the device pixel ratio, while `DecodeTarget.fit` preserves a known source aspect ratio inside that physical viewport. Both paths align dimensions to eight pixels and enforce a bounded decoded-pixel budget.

The static reader recreates its diagnostic binding when MediaQuery dimensions or DPR change. The Animated WebP preview derives its target from the exact `LayoutBuilder` image area, so app bars, controls, rotation, split-screen, and device density are reflected in decode identity.

### Flutter codec scaling

The Flutter path no longer places an intrinsic-size `Image.memory` inside a loose `Center`. It receives tight full-area constraints and matching physical `cacheWidth`/`cacheHeight`, with medium filtering. Tiny bundled fixtures now fill the preview correctly, while large imported files are decoded to the same bounded physical target as native.

### Native pacing

The previous preview decoded the next frame only after the current frame timer expired, making wall time equal to encoded duration plus decode/image-construction time. The player now decodes and builds the next `ui.Image` while the current frame is visible. `FramePacing.remaining` subtracts that preparation time from the current frame duration and presents immediately on overrun. Pause/resume preserves pending deadlines, and finite playback waits through the final frame duration before reporting completion.

### Next iteration

1. Replace diagnostic RGBA-to-`ui.Image` copies with Android texture upload.
2. Feed viewport target revisions into real reader decode sessions without recreating diagnostic controllers.
3. Add device timing telemetry comparing encoded, decode, upload, and present intervals.
4. Add local chapter/CBZ import and persistent catalog entries.

## 0.16.0-dev.16 — runnable Animated WebP app entry and local import

### Bundled animation assets

The three deterministic native decoder fixtures are now copied into the Flutter
asset bundle with a checked catalog. Repository validation compares the bundled
bytes with `native/media_core/testdata`, validates RIFF/WEBP headers and declared
byte lengths, and requires all three entries to remain reachable from the app.

### App navigation and local import

The app now opens a demo home instead of entering the 100-page static chapter
automatically. Separate entries open the static reader, a bundled Animated WebP
catalog, and the platform file selector for a local `.webp`. Local files are read
through `XFile` bytes, so the preview does not depend on a manifest or direct I/O
in the reader package. `file_selector` 1.0.3 preserves the current Dart 3.6 SDK
floor.

### Native preview path

The Animated WebP preview creates a `NativeSource`, appends and seals the selected
bytes, validates the pinned libwebp runtime, creates a typed native cursor, copies
`PixelFrame` RGBA bytes into a Flutter `ui.Image`, and follows native duration and
loop metadata. RGBA is premultiplied before presentation. The user can switch to
Flutter's codec for comparison. Missing or invalid native libraries cause an
automatic Flutter-codec fallback instead of a blank page.

### Next iteration

1. Replace the diagnostic RGBA copy with the Android `SurfaceProducer` texture
   registry and serial native blit worker.
2. Connect reader page roles to the real native player instead of the standalone
   preview route.
3. Add import of a local directory/CBZ chapter and persist the resulting catalog.
4. Add Android device tests for lifecycle-safe output retirement and overlap.

## 0.15.0-dev.15 — pinned libwebp source builds

### Source ownership

Host and Android builds no longer accept prebuilt per-ABI libwebp directories.
`native/libwebp.lock` pins libwebp 1.6.0 to the official WebM repository and
commit `4fa21912338357f89e4fd51cf2368325b59e9bd9`. `fetch_webp.sh` creates a
shallow detached checkout and verifies the exact commit before any native build.
A local source override is rejected unless it is the pinned git checkout or the
caller explicitly enables an unpinned development source.

### Reproducible host and Android builds

`build_webp_host.sh` and `build_webp_android.sh` use the upstream CMake project
with only libraries enabled. Build and install outputs are isolated below
`.deps` by source version, platform, ABI, mode, and link type. Android uses the
NDK CMake toolchain for arm64-v8a, armeabi-v7a, and x86_64. `media_core` links
those generated artifacts; no downloaded binary archive is accepted.

Android defaults to PIC static archives linked into `libmedia_core.so`, avoiding
versioned shared-library SONAME dependencies in `jniLibs`. An explicit shared
mode remains available for diagnostics. Android assets include upstream COPYING, PATENTS, and exact
source provenance.

### CI and local checks

Host C smoke and Rust tests now build the pinned source first. CI no longer
installs a distribution `libwebp-dev` package and has a dedicated Android-native
job that builds all configured ABIs. Flutter-only split APK CI uses
`ZIC_ANDROID_NATIVE=0`; normal `build_android.sh` includes native media by
default. ABI v5 also exposes the linked decoder and demux versions; the Dart
bridge reports whether both equal the pinned 1.6.0 packed version.

### Next iteration

1. Add the Kotlin `SurfaceProducer` texture registry and serial blit worker.
2. Pass retained frame handles through JNI without MethodChannel pixel copies.
3. Separate texture creation, first blit, present, and lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

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
