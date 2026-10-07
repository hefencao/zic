# ADR 0355: Cold chapter load awaits existing source activation

- Status: Accepted
- Date: 2026-10-01

## Context

Second-device normal Profile export `03-14-36` records a persisted comic's
details first frame before deferred source activation. Opening an unpersisted
chapter fails at `t29648731` with source unavailable, but the same activation
publishes an available source at `t29859567`. Local details only checked the
synchronous live resolver and widget source, ignoring the route's pending
activation Future.

## Decision

Pass that existing activation Future to `LocalComicDetailsScreen`. Its cold
chapter materialization awaits the Future only when no source is available,
then resolves the current source again. A disposed details State does not start
materialization after activation. Cached chapter records retain their immediate
path. A null activation result with no live source remains one terminal error.

No activation owner, retry, poll, timer, network gate or source mirror is added.
Home owns activation; NetLane retains transport scheduling. Details still paints
its local projection before activation.

## Validation

Production-behavior failing-first regressions report the same unavailable-source
error while activation is pending. Five lifecycle regressions cover cold wait,
cached entry, terminal absence, disposal and stale activation snapshots; together
with details status and Reader composition they pass 17 tests. The first fixture
incorrectly reused one chapter revision across different identities and is
excluded from product failing-first evidence. Required-toolchain checks pass2148 Dart/Flutter tests and Rust22. Normal
Profile opens unpersisted chapter36 with its loader1.120s before source
readiness, waits successfully, and exports1109 events with zero failures.
