# ADR 0348: Complete WebP late join preserves published source

Status: Accepted

## Context

An initial WebP replay probe can cover a complete sealed body. Its source is published to decode before final fan-out attachment. The suffix branch excluded sealed sources and rebuilt from byte zero, disposing a source already bound by a cursor at the same epoch.

## Decision

At the existing synchronized late-join owner, reuse a published source when epoch, committed length, sealed state and failure match the physical boundary. Partial suffix growth still appends on the same source; changed physical boundaries retain existing replay and final attachment checks.

## Consequences

The fix prevents invalid lifetime replacement rather than swallowing native disposal errors. No cache budget, worker capacity, decode policy or source-lock boundary changes. A failing-first identity regression and existing partial/epoch/promotion tests validate the owner boundary.

## Verification

DownloadSession90/90 and final required-toolchain checks pass. The final complete 15-50-39 Profile trace contains 364 decoded frames, animated exit/reentry and no failures. Exact late-join identity remains deterministic regression evidence, rather than a device fault-injection claim. Evidence: [chapter-boundary audit](../audits/chapter-boundary-trace-regressions-2026-09-30.json).
