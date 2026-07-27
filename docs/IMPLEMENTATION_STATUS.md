# Implementation Status

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
