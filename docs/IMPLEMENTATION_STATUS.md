# Implementation Status

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
