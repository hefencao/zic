# ADR 0352: Venera complete collection pagination

Status: Accepted

## Context

Real installed Venera JM declares `multiPartPage`. Its `load` returns every
homepage group and ignores numeric page arguments. The adapter sliced at
`offset % limit`, so offset 24 repeated all 24 first-page items and remained
pageable. The source contract passes null for this single collection.

## Decision

The existing runtime adapter invokes `multiPartPage.load(null)` and wraps the
flattened collection without modifying the source result. It slices at the
global offset and derives `hasMore` only from remaining collection items.
Ordinary numeric-page loaders and retained `loadNext` cursor state keep their
existing contracts. No new pagination cache, source special case or UI owner
is introduced; Reader, NetLane, windows and resource budgets are unaffected.

## Validation

`tool/test_venera_bootstrap.py` first failed with a repeated first slice. It
now verifies frozen groups spanning three slices, explicit/default section
selection, exhaustion and null page arguments, plus ordinary-page and cursor
behavior. Real minified JM returned all 180 items as seven 24-item pages and
a final 12-item page, then an empty exhausted page; page2 overlap is zero.
The all-source minified rerun passed 144 steps. Required-toolchain gates
completed all static, analyzer, 2136 Dart/Flutter, Debug three-ABI and 22 Rust
checks. Evidence is in source-device-acceptance and state-governance audits.
