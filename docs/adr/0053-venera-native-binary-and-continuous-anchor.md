# ADR 0053: Venera native binary transport and stable continuous anchors

Status: Accepted in `0.31.0-dev.69`.

## Context

The durable locator work in dev.65–68 solved only resource identity. Device traces still showed the same Venera page re-entering decode/upload plans across unchanged observations, large image responses timing out in the WebView bridge, and detached demands continuing until timeout. Continuous layout also recentered on every geometry update, while an old per-comic `false` value could silently disable global stitching. The vertical regression test still read a lazy separator before it existed.

## Decision

1. Keep `venera-resource:` as a reconstructable source configuration identity, but transfer ordinary response bytes through a native one-shot token. Use JS bytes only when the source declares response or bitmap transformation.
2. Strip bodies from GET/HEAD. Serialize Venera invocations, request only the current Reader page, and suppress unchanged pipeline role maps.
3. Propagate invocation requestId into bridge HTTP calls. Track native connections by request and disconnect/cancel them when the host cancels the invocation.
4. Model per-comic stitch as nullable override. Migrate historical false to inherit because previous UI wrote false even when users only changed direction.
5. Preserve the viewport-center page/fraction through geometry or viewport changes. Do not restore while dragging/scrolling.
6. Use no separator in stitch mode and overlap adjacent painting by one logical pixel. Keep media fit-width and uncropped.
7. Give loading indication to the Reader viewport; page media reports readiness but suppresses duplicate internal spinners.
8. Lazy-list tests must establish finder cardinality before widget retrieval.

## Consequences

- Normal Venera images avoid image-sized Base64/JSON allocation and WebView round trips.
- Cancellation stops network work rather than only hiding its result.
- Venera prefetch is intentionally conservative until device traces support expansion.
- Continuous reflow no longer forces users back to a page center.
- The JS transformation compatibility path remains slower and bounded by the same runtime limits.
