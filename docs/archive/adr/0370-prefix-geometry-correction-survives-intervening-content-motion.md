# ADR 0370: Prefix geometry correction survives intervening content motion

Status: Accepted

## Context

An ordinary Release loading trace exposes a first drag sample moving from
64.388 to66.122 logical pages in18.090ms while physical pixels move only11.865.
The source input clock is healthy, so ADR0369 input-time sampling does not
explain this geometry discontinuity.

A controlled widget reproduces the layout handoff: two prefix pages change
ratio while dragging; idle prepares their top-anchor correction in a post-frame
commit. A new drag starts before the next layout. ScrollStart retires both the
navigation anchor and the still-unapplied geometry correction. The next layout
installs the changed prefix without its compensation, introducing an extra600px
jump. Keeping only an absolute prepared target would instead discard real
motion arriving between preparation and layout.

The initial correction draft memoizes its target. Existing frame-timing context
also resolves that target, so a diagnostic read can freeze it before subsequent
input. Directional regressions reproduce100px of lost movement in this draft.
Diagnostics cannot own geometry application.

## Decision

Reader's private one-frame prefix correction carries the physical pixel value
at preparation. At its first layout application it adds the intervening real
pixel displacement to the prepared target, then retains that target across
repeated layout passes. This is the existing geometry transaction, owned by
Reader layout; it introduces no resource or scheduling state.

ScrollStart keeps an unapplied motion-preserving prefix transaction. Existing
absolute slider and real-tail corrections retain their navigation retirement
behavior. Frame-timing context uses a pure preview; only ScrollPhysics layout
resolution can fix the transaction target. The existing frame-end clear retires
the applied correction so it cannot consume later motion.

Applied-geometry observation, source-time velocity, slider/first/last semantics,
controller replacement, workers, NetLane, resource windows and native ingress
remain under their existing owners and contracts.

## Validation and limits

The original controlled handoff fails before the change with page top-800px
instead of-200px. Two directional production regressions additionally fail the
draft when timing context is read before input, losing100px. The revised
implementation passes both directions and verifies physical movement, repeated
layout stability, subsequent movement and its source-time velocity.

The combined required gate passes2190 tests across27 Dart/Flutter suites,
22 Rust tests and three Android ABI/JNI checks. Ordinary Release exports8183
and5548 events without truncation, with13 active dimension updates across two
runs. Both retain correct slider and chapter boundaries, no motion outlier, and
active extent-matched render observations without the reproduced600px jump.
ADR0371 separately addresses comparing different logical coordinate systems.
These are scoped observations, not final-display proof: a48.162ms
drag-to-ballistic callback handoff gap, entry CPU, final display and source acceptance remain
open. Evidence is recorded in the loading/chapter/plugin regression audit.
