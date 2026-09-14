# Resume Range provenance audit — 2026-09-14

## Trigger

Process-death validation proved that durable READY and mutable partial bodies survive `am force-stop`, but a resumed partial could still appear to “redownload from zero”: a nonzero overlap probe was followed by HTTP 200 and full-body prefix catch-up. The remaining question was whether zic lost the `Range` header before the request reached the production Android HTTP adapter.

## Ownership boundary

Resume policy remains in `DownloadJob`. A validatorless partial keeps its durable committed prefix, opens a 64 KiB overlap probe from `committedLength - 64 KiB`, accepts a real 206 only when the returned range matches, and treats a 200 as full-body response semantics. It may defer costly prefix catch-up at lower priority; when completion becomes sufficiently important it reuses that already-open 200 body, verifies continuity against the preserved prefix, and appends only after the durable boundary. No Reader/App lifecycle input participates.

The source path is transport-only. `normalizeSourceResourceRequest()` converts `ByteRange(start: N)` to `Range: bytes=N-` and optional strong validators to `If-Range`; the normalized request then reaches `RhttpSourceResourceDirectTransport`, which passes the same header map to `rhttp.HttpHeaders.rawMap(request.headers)` for `requestStream`.

## Regression and production diagnostic

A new focused downloads regression proves the transfer-owned range request reaches the direct source-open boundary unchanged: start `6,743,904` becomes `Range: bytes=6743904-`, ETag becomes `If-Range`, and unrelated source headers survive. The rhttp adapter adds diagnostics only—no request/retry behavior—to expose the exact request-side Range header present on the request map passed to rhttp and whether If-Range exists.

Host Flutter tests cannot initialize the native rhttp client in this environment, so a localhost rhttp integration test was deliberately not kept and no test-only injection seam was added to production. The direct production proof therefore comes from Android profile trace.

## Device proof

Profile APK was rebuilt and installed with `adb install -r`, preserving data. Fresh trace `zic-debug-trace-2026-09-14T05-27-27.jsonl` recorded two resumed partial origin opens whose production rhttp diagnostics included exactly:

- `sourceRequestRangeHeader: bytes=3876464-`
- response `statusCode: 200`
- response semantics were full-body (`rangeStart` resolves to zero at the transport boundary)

Both opens used the normal direct source path. This proves the Range header was still present at zic's final production adapter boundary immediately before `rhttp.requestStream`; the HTTP 200 therefore occurs downstream of zic source normalization/plugin bridging rather than because local cache state or the zic bridge silently discarded Range. A redirect/CDN/origin layer may still choose or cause full-body semantics, so the evidence does not claim which downstream hop ignored the Range.

## Consequence

No resume behavior was loosened. In particular, HTTP 200 is not treated as 206, existing durable prefix bytes are not discarded, and suffix append still requires continuity proof. The visible repeated network prefix for these responses is a downstream Range-support/response behavior issue, not process-exit cache loss.

Validation after the diagnostic/test addition: focused source transport **25/25**, downloads_bridge **2/2**, full Downloads **407/407**, Android profile build/install successful; targeted analyzer has no errors/warnings (existing info lints only).
