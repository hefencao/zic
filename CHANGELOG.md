# Changelog

## 0.10.0-dev.10

- Replaced the stale `ReadingDirection.leftToRight` test value with `ltr`.
- Added `ReaderBinding` to drive demand reconciliation and viewport playback
  from the same reader observation, and connected the demo app to the binding.
- Added decoded-frame and renderer-output byte budgets with current-page
  reserves and low-priority non-current trimming.
- Added output byte accounting, claim-safe frame/output trimming, and frame
  budget telemetry in `LiveCoordinator`.
- Added reader-binding and frame-budget integration tests plus regression gates.

## 0.9.0-dev.9

- Removed invalid trailing commas from native source enum index expressions.
- Added split-per-ABI Android APK builds through `tool/build_android.sh`.
- Switched CI and full toolchain checks from fat APK to split APK output.
- Added viewport idle/dominant/overlap/continuous phase resolution.
- Added playback gating and coordinator integration for viewport freeze/resume.
- Added regression tests for discrete overlap, target dominance, continuous
  scrolling, and playback-gate state transitions.

## 0.8.0-dev.8

- Fixed duplicate upload work caused by source-ready and download-complete wake-ups.
- Counted renderer-owned ready output toward the decode watermark.
- Added non-cancelling lane follow-up work with per-key coalescing.
- Added explicit frame advancement; source progress alone no longer advances playback.
- Added a playback timer whose duration starts after actual present, with freeze/resume.
- Added regressions for duplicate upload, prepared depth, lane follow-up, and playback timing.

## 0.7.0-dev.7

- Imported `EncodedSource` in the frame cursor contract.
- Fixed `Artifact.readPrefix()` closing its random-access file before the
  asynchronous read completed.
- Added an immediate prefix-read/file-close regression test.
- Added renderer-owned output frame and frame uploader contracts.
- Added upload sessions and registry with upload and present claims.
- Deferred output disposal while a present claim remains active.
- Rejected and disposed stale upload results.
- Connected successful decode work to upload-demand wake-up.
- Added upload state, uploaded-frame, and presented-frame telemetry.

## 0.6.0-dev.6

- Fixed restored sniff prefixes being stored as unmodifiable lists.
- Changed artifacts to open partial writers lazily and serialize writes.
- Removed idle file handles from startup recovery and cache scanning.
- Added source-ready/source-disabled telemetry and early decode wake-up.
- Added frame/cursor contracts, frame holder claims, decode sessions, and a
  decode registry keyed by `DecodeId` and source epoch.
- Made coordinator idle detection stable across work submitted by other lanes.
- Added regression coverage for the reported session failures and decode flow.
- Copied queued byte chunks at ownership boundaries and isolated
  source-listener failures.
- Disposed frames decoded after cancellation or epoch supersession.
- Fixed coordinator upload dispatch and cancellation of detached active
  downloads during dispose.

## 0.5.0-dev.5

- Fixed the missing `DownloadSession` import in `LiveCoordinator`.
- Moved `RetryPolicy` duration validation out of const evaluation.
- Added the pure Dart media contracts, source pool, and format-aware ingress.
- Mirrored confirmed WebP downloads into native encoded sources while keeping
  artifacts authoritative.
- Rebuild encoded sources from restored partial/final artifacts.
- Added ingress and download-integration regression tests.

## 0.4.0-dev.4

- Fixed Flutter platform-generation and test working directories.
- Added explicit Flutter and Dart package test runners.
- Added cache limits, LRU planning, safe trim/clear, and released-byte reports.
- Added bounded retry/backoff for demanded failed downloads.
- Added decode, upload, and maintenance lane shells.
- Added Rust incremental byte-source ABI and Dart FFI wrapper.

## 0.3.0-dev.3

- Renamed the reserved `library` package to `catalog`.
- Added cache index, scanner, startup recovery, network lane, and live download
  coordination.
