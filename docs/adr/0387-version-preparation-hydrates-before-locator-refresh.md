# ADR 0387: Version preparation hydrates before checking source locators

Status: Accepted

## Context

A strict ordinary-device backup comparison found a target chapter's import time
changed after viewing a confirmed same-source version. Its identities, page
locators, revision and progress were unchanged. Version warmup checked compact
Home placeholders before hydrating the complete stored manifest, so the shared
locator predicate correctly rejected the projection but triggered an unnecessary
source load. This does not establish the original Mihon19/20 loading root cause.

## Decision

The existing HomeVersionReuseLifecycle asks HomeLibrarySession to hydrate an
existing target entry first. After the await it checks scheduler cancellation,
then applies the unchanged locator predicate to the authoritative result. Valid
complete manifests are returned unchanged. Missing pages, remaining placeholders
and obsolete locators continue through the existing controlled source load,
identity validation and session upsert. No new owner, schema, retry, queue, cache
identity, trust rule or Reader/Pipeline scheduling policy is introduced.

## Validation

Failing-first tests use the production compact snapshot codec and locator
predicate. They require a valid stored chapter to avoid source reload and retain
its complete record/progress, require a legacy locator to refresh, and require
cancellation during hydration to prevent source loading or upsert. The required
gate passes 2227 Dart/Flutter tests and 22 Rust tests; all three Android ABIs pass
Profile/Release packaging. Ordinary Release strictly preserves all 119 chapter
records and every other exported section across upgrade and readonly version
view. Five stationary slider and five chapter-boundary samples pass, including
overriding saved middle-page history with the requested first/last page.

The continuous overlapping exports retain 12417 events, 285 artifact-cache
reads, no download start and no task failure. This does not close the original
intermittent loading report or final-display performance. A separate chapter20
import-time change during explicit details selection remains tracked in the
details-preparation audit; it is not discarded from the strict comparison.
Evidence:
`docs/audits/compact-version-preparation-hydration-2026-10-03.json`.
