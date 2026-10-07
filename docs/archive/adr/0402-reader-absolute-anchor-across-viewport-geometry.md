# ADR 0402: Reader absolute anchor across viewport geometry

Status: Accepted

## Context

Actual Android rotation after a correctly seeded slider changes page86 to85.
The existing absolute navigation anchor survives late source ratios but viewport,
DPR and stitch changes use ordinary top restoration. Eight independent widget
cases reproduce the first-layout error for released sliders and interior entry.
Content-motion retirement already passes.

DPR changes also replace Flutter's ScrollPosition. Its first content-dimension
pass skips adjustPositionForNewDimensions, so computing a pending center target
alone does not apply it. The first candidate passes viewport and stitch cases
but fails all four DPR cases.

## Decision

Project the changed viewport and DPR through the existing ReaderVerticalGeometry.
An idle absolute navigation anchor uses the existing layout correction across
ratio, viewport, DPR and stitch changes. Clear ordinary top restoration when the
absolute center takes precedence.

A vertical ScrollController/ScrollPosition adapter applies that same pending
correction during a replacement position's first dimension pass, using the real
incoming min/max extents before accepting layout. Subsequent dimension passes
continue through the existing ScrollPhysics. The adapter has no additional
anchor, scheduling or resource state.

## Consequences

Layout correction preserves navigation without jumpTo scroll notifications.
Real content motion, new commands and direction/controller replacement retain
their existing retirement rules. Ordinary top anchors and real chapter tails
keep their existing priority and range semantics. Reader consumes read-only
Pipeline output; source identity, cache/trust, transport and lane budgets remain
with their existing owners.

Evidence: `docs/archive/audits/reader-viewport-DPR-acceptance-2026-10-05.json`.
Eleven new stable cases and105 focused cases pass. Required toolchains verify
2320 Dart/Flutter tests,27 analyzers, Rust22, Android108 and six ordinary
Profile/Release APKs. Ordinary Release verifies28 steps including16 actual OS
configuration changes, absolute centers, stitch and real tails with insets.
All125 full chapter payloads remain exact. Original intermittent19/20 loading,
active-scroll visual continuity and physical-display performance remain open.
