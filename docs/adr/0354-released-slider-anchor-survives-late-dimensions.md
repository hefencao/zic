# ADR 0354: Released slider anchor survives late dimensions

- Status: Accepted
- Date: 2026-10-01

## Context

The normal Profile on the second device exports `02-41-12` with 1084 events. A stationary slider selects page114, releases with `interaction=idle/logicalPosition=113.5/velocity=0`, and receives its first measured 720×700 dimensions 1.129s later. The viewport remains at the provisional page's start; its smaller extent moves the center into page115 and creates velocity0.486 without input. All target/neighbor first frames subsequently arrive without vertical input, so this defect is separate from the earlier loading stall.

Reader clears `_verticalScrubAnchorIndex` at release/completion and idle observation whenever no ratios are pending. No pending ratio is not evidence that the selected page's size has been measured. A later ratio therefore uses ordinary top anchoring and changes the selected center. Both already-acknowledged and pending-layout release regressions fail with expected index3, actual4.

## Decision

Keep the existing last absolute slider selection as geometry anchor after input release. Subsequent idle ratio adoption uses that selected center through the existing atomic layout correction. Retire the anchor on actual content motion, a new page/viewport command, direction change or Controller replacement. Use no media-ready fact, timeout, additional state owner or Pipeline/network gate. Pointer-up still ends scrubbing immediately; first-frame and resource execution remain independent.

This refines ADR0345's deferred-geometry anchor retirement, while preserving its navigation-completion and zero phase-velocity decisions. It does not alter encoded7/3, decode2/1, NetLane, viewport-step animation, chapter first/last entry or scroll physics.

## Validation

Two failing-first widget variants release before or after layout, then deliver selected and adjacent ratios in separate later turns. Both must keep the same centered selected page and zero velocity, and a subsequent physical drag must regain ordinary top anchoring. Device evidence and final toolchain status are recorded in `docs/audits/slider-late-dimensions-2026-10-01.json`; full required-toolchain checks pass 2140 Dart/Flutter tests and Rust22. Normal Profile device runs select pages116 and21; dimensions arrive807.560ms and950.559ms after release, first frames arrive without vertical input, and selected pages remain stable. Subsequent real content motion advances21→25. Four previous/next crossings enter exact last/first pages, overriding saved history.
