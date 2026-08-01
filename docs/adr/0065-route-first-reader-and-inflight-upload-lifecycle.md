# ADR 0065: Route-first Reader, host-streamed Mihon and in-flight upload lifecycle

## Status

Accepted for `0.31.0-dev.81`. Supplements ADR 0061–0064.

## Context

The dev.80 device trace separated two behaviors that had previously been mixed:
artifact/cache copies entered DownloadSession in 64 KiB chunks, while uncached
Mihon origin pages arrived as one multi-megabyte `sourceReady` followed by one
same-size `bytesCommitted`. The Mihon adapter had hard-coded
`requiresRuntimeTransform=true`, so the plugin runtime downloaded the complete
image before Pipeline could observe any bytes.

The same trace showed a rapid current/transition change while an Android texture
upload Future was active. `UploadSession.detach` released the uploader slot
before that Future settled; the old revision later emitted
`Failure(texture): frame upload failed` and polluted the newer revision.

Chapter navigation still awaited source chapter loading, refresh, artifact
inspection and loader composition before `Navigator.push`. Existing regression
tests also depended on real loopback sockets, 30-second wall-clock timeouts,
lazy child mount state and magic pixel thresholds.

## Decision

- Mihon runtime `resolveResource` returns only the final URL, headers, null-body
  GET method and transform flag. The shared host transport streams the response
  directly into the existing DownloadSession. `loadResource` remains a
  compatibility fallback only after the direct request and a refreshed request
  plan both fail.
- GET/HEAD normalization is one downloads-owned function: no body, no entity
  headers, identity content encoding and optional Range/If-Range.
- DownloadSession owns `networkStartLength`, the partial length at which one
  network writer/run begins. Pipeline transfer UI derives connecting/receiving
  from this snapshot and keeps no second guessed baseline.
- UploadSession owns the whole asynchronous upload lifetime. detach/reset/
  dispose request uploader retirement. Platform uploads for the same stable
  `DecodeId` are serialized; release executes only after queued/active upload
  operations drain. Any result or error from a superseded revision is converted
  to cancellation and cannot update current state.
- Chapter selection pushes a deferred black Reader route immediately. Source
  chapter loading, refresh, artifact inspection and loader composition execute
  inside that route; successful preparation replaces the loading shell without
  a second navigation.
- Ordinary images and WebP use the same centered media viewport. Continuous
  geometry is tested through `ReaderVerticalGeometry`, its owner value object.
- Downloads transport and App artwork-gateway tests use controlled responses;
  upload and route tests use controlled Futures. Reader double-tap timing uses
  the injected monotonic clock. Tests and static gates do not depend on real
  sockets, `pumpAndSettle`, fixed delays, lazy children or arbitrary offsets.
- Android Trace export remains App-owned but uses the Intent/result lifecycle
  available on `FlutterActivity`, not `registerForActivityResult`.

## Consequences

- Uncached Mihon pages can expose incremental committed bytes and first-frame
  decode before full completion when the remote response and format permit it.
- Sources that require private OkHttp interceptors can still fall back to the
  existing source-owned request after host direct streaming genuinely fails.
- Current-page progress switches to receiving after the first byte added in the
  active run, including unknown-length responses.
- A page transition cannot retire a texture slot while an upload still uses it;
  an older revision also cannot upload concurrently into the same slot or stop
  the new playback revision.
- Reader route presentation is no longer serialized behind plugin/network
  chapter preparation.

## Rejected alternatives

- Treating complete-byte plugin RPC as the normal Mihon image path.
- Waiting for full download before decode.
- Keeping every texture alive for a chapter or shrinking windows/concurrency.
- Waiting for chapter preparation before navigation.
- Adding WebP-only alignment or progress cases.
- Preserving real-socket, fixed-time, lazy-child or magic-offset tests.
