# ADR 0357: Unchanged chapter upsert preserves media authority

- Status: Accepted
- Date: 2026-10-01

## Context

Second-device chapter boundary requests take3.53–3.80s. Their matching Home
logs show two UI-isolate canonical authority rebuilds of494–495 hydrated
chapters, each taking1.60–1.86s. `_rememberVersionAuthorityEntries` always
marks full source upserts changed, even when their complete persisted payload
is identical, and `_upsertChapter` refreshes the scope again afterward.

Revision/page count alone cannot identify unchanged request authority: Venera
may replace its exact provider locator within the same revision.

## Decision

Keep the new full chapter and the newer progress in the existing Home owner.
Compare the complete persisted chapter payload with the previous hydrated
chapter before refreshing its media authority. A reloaded identical record
preserves the published scope; a real provider/metadata change still publishes.
Remove the unconditional second refresh after canonical assimilation, whose
existing commit path already publishes any changed canonical projection.

Do not add a manifest cache, fingerprint owner, queue or asynchronous authority
publication. Durable target-chapter persistence and final progress flush remain
before the boundary commits. Source identity, proof revocation, request carrier
replacement, NetLane and all Reader budgets remain unchanged.

ADR 0358 later permits record-local immutable manifest projection reuse. The
scope-level cache/owner and asynchronous publication exclusions remain in force.
ADR 0365 compares those same values directly without serialization and permits
reusing an equivalent incoming prepared record after the durable exact read.
Actual source/metadata changes and latest progress remain authoritative.

## Validation

The deterministic regression observes existing authority rebuild diagnostics,
including zero-millisecond operations. Before the fix an identical deserialized
chapter rebuilds twice; after it rebuilds zero times, while a same-revision
provider change publishes once and replaces its locator. Home/session/version
and Reader composition suites pass86 tests. Required-toolchain checks pass2148 tests and Rust22. Four
normal Profile cached crossings enter exact first/last pages without repeated
authority rebuilds and complete in12–20ms. The before sample hydrated494–495
chapters and the after sample2–3, so this is no equal-size performance comparison.
Detailed proof and boundaries are in `docs/audits/chapter-authority-noop-2026-10-01.json`.
