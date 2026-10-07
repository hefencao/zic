# ADR 0388: Details chapter preparation hydrates before source fallback

Status: Accepted

## Context

A strict ordinary Release backup comparison after Reader navigation found only
chapter20's import timestamp changed among 119 complete chapter records. Page
payloads, URIs, revisions and identity sets were unchanged. Details correctly
rejects compact Home placeholders as command authority, but its existing Home
chapter-ensurer immediately reloads the source. It never asks the existing
library session for the complete durable record before that fallback. This is
separate from version warmup and does not establish the original intermittent
cache/loading cause.

## Decision

The existing Home details chapter-ensurer first locates the exact
source/comic/chapter candidate and hydrates it through HomeLibrarySession.
Only a complete record matching that identity, the existing details revision
and page-count predicate, and the existing locator predicate may be returned.
Changed revision/count, missing records, remaining placeholders and legacy
locators retain compatible source loading and upsert. Full-page authority and
mutable progress remain owned by the same session/store. Details presentation
candidates still cannot authorize placeholder bytes or historical page reuse.

No owner, queue, schema, cache identity, trust rule, Reader eligibility or
network scheduling policy is added. Source refresh and changed provider
locators must retain their existing replacement behavior.

## Validation

Tests exercise the actual Home callback attached to the details route, with
the production compact snapshot codec and complete targeted store reads.
Failing-first passes all five necessary source-fallback cases and fails the two
valid stored-record cases with one unexpected source load each. After repair,
42 focused checks and the required 2234 Dart/Flutter plus 22 Rust checks pass.
All three Android ABIs pass Profile/Release packaging, native JNI/FFI and
Dex/AOT/source checks. Ordinary minified Release with the verified source
snapshot passes strict upgrade comparison and preserves all 119 complete
chapter records, including import times, locators, revisions and nested page
order, after actual Reader navigation. Only progress/read-state changes from
the three read chapters remain. Five stationary slider and five chapter-boundary
samples pass, including both saved middle-page overrides. Correct Mihon device
metadata and download display are reverified.

Continuous overlapping one-click exports retain 12169 exported records, 285
artifact-cache reads, no page download start and no task failure. This is a
scoped metadata/source-fallback acceptance. It does not close the original
intermittent loading report, continuous-scroll GC/CPU or final-display
performance; a 101.623ms frame with 100.469ms vsync overhead remains unattributed.
Evidence: `docs/audits/details-chapter-preparation-hydration-2026-10-03.json`.
