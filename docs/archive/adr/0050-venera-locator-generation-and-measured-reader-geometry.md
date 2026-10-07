# ADR 0050: Venera locator generation and measured Reader geometry

Status: Accepted in `0.31.0-dev.66`.

## Context

dev.65 introduced reconstructable Venera resource locators, but its global restore helper referenced `source` from the local operation scope. Every new locator therefore failed. Existing imported chapters and cached metadata could still contain `venera-resource://token` values that were valid only in a previous runtime generation, and Reader policy revisions retried those deterministic failures. Continuous vertical layout also guessed a full/tall page extent when metadata lacked dimensions, leaving large black regions around a contained image. Direction changes could acknowledge navigation before the replacement scroll controller had completed layout, making page number and top navigation appear inert.

## Decision

- Resource configuration restoration receives the active Venera source explicitly. The durable payload remains constrained to version, original image identity and comic/episode identity.
- Chapter metadata cache keys include a durable-locator schema revision. App compatibility loading detects persisted generation-only locators, uses the chapter-refresh capability to bypass the old response and reloads the chapter before opening or downloading.
- A Venera runtime stores a bounded resolved configuration per durable locator and coalesces concurrent resolution. The Dart source adapter coalesces concurrent identical resource invocations and removes the Future after completion. Neither mechanism retains completed page bytes.
- Continuous Reader page extent uses source geometry first and runtime-observed geometry second. Static image headers are read from the same bytes already obtained for decoding; WebP uses existing container metadata. Unknown pages use a conservative temporary ratio and reflow after measurement. No crop and no second ImageStream are permitted.
- Direction/layout and page commands remain pending until the target PageController or ScrollController is attached and reports usable dimensions. The Reader acknowledges a request only after executing the jump, then publishes the resulting observation.

## Consequences

Venera pages survive runtime replacement without repeated source-page resolution during one runtime, while stale legacy chapters are deterministically replaced rather than retried. Request consolidation lowers duplicate work but preserves existing page-byte ownership and eviction behavior. Vertical stitching reflects actual media geometry and never removes image content. Top controls keep a single command contract across paged, RTL and continuous presentation.
