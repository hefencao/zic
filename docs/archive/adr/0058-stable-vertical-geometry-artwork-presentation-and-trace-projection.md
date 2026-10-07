# ADR 0058: Stable vertical geometry, artwork presentation, and trace projection

Status: Accepted in `0.31.0-dev.74`.

## Context

Three regressions shared one pattern: Presentation reconstructed information that an upstream owner already knew. Reader inverted runtime image dimensions and discovered a distant saved page by mounting a long prefix; source/detail covers converted durable cache files back into transient byte images; Debug Trace rendered every lifecycle event and full Mihon opaque identity.

## Decision

1. Continuous page geometry uses one unit, `height / width`, from source metadata through runtime measurement and sliver extent calculation.
2. The vertical list exposes predictable per-item extents and establishes its saved-page offset before attachment. Stitch mode has neither a separator nor a negative translation.
3. `ResourceCacheManager` remains the only artwork-byte cache. Presentation receives `EncodedResourceSource` and uses file-backed image providers on warm hits. Artwork cache generation is independent of chapter revision and validates the encoded container before persistence.
4. `DebugTraceLog` remains an observational bounded projection. It may coalesce consecutive high-volume lifecycle events for display, while failures remain individual. The diagnostics screen owns filtering, severity accents, copy, and JSONL export.

## Consequences

- Restoring page 87 performs arithmetic over the extent index but does not construct pages 0–86.
- A runtime dimension update cannot shrink a portrait page to its inverse height or paint into the next page.
- Route re-entry reuses the same durable cover file/provider identity rather than rebuilding a `MemoryImage` from bytes.
- Debug logging remains useful without changing Pipeline behavior or losing actionable failures.
