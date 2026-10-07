# ADR 0401: Details preview single-row height bound

Status: Accepted

## Context

The existing preview paginator limits the sum of rows but accepts an oversized
single row. A real details-widget test at 800×400 renders a 48×240 PNG in an
800×1777.78 tile, exceeding the SPEC's screen-height limit. Shrinking an entire
row would violate the full-width contract; clipping would hide image content.

## Decision

Pass the existing page height into row construction. Ordinary rows retain their
original geometry. Only an oversized row solves equal-area tile widths with
each tile height bounded by that height. Capped tiles may have a different box
aspect; the existing contain painter preserves the complete image.

The finite capped set consumes no new state or owner. Complete rows still use
the full media width. Existing source order, local reorder, row-count limits,
page indicator allowance and sparse final-row area cap remain intact. Folded
and expanded views consume the same first-row geometry.

## Consequences

Very tall previews in a short window can have horizontal space inside a tile.
Image loading, cache/crop identity and all Reader/Pipeline/runtime scheduling
and lifecycle contracts stay with their existing owners. This repair makes no
claim about Reader intermittent loading or display performance.

Evidence: `docs/archive/audits/preview-height-bound-2026-10-05.json`.

Five stable widget regressions and the existing preview/source-browser tests
pass. Fourteen actual Android controlled-window cases verify row limits,
pagination, equal area, full width, sparse area and folded/expanded geometry.
PNG end markers pass with 28 background-replacement negative controls.
Repository/toolchain checks, Android units, three-ABI packaging and ordinary
cached Reader functional revalidation pass. Actual OS rotation and broader
source/Reader loading or physical display performance remain independent work.
