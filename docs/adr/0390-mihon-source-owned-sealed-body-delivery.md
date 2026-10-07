# Mihon source-owned sealed body delivery

Status: Provisional

## Context

Unknown/custom Mihon clients must execute their own requests and interceptors.
Their compatibility `loadResource` previously returned a complete `ByteArray`
through the runtime engine, an IPC codec envelope and the host Dart result.
Existing `.packet` files contain envelopes and cannot serve as raw images.
This is an established full-body allocation boundary; it is not proof of the
reported chapter19/20 loading cause or of the3.9s upstream-read attribution.

## Decision

Negotiate `sealed-file-v1` through both the source descriptor and the runtime
connection. Existing source invocation/packet owners produce a bounded raw body
file from the same source client's response stream and close the response before
the invocation finishes. Preserve request method/headers/body, client and payload
authority, and the signed64-bit FNV validator used by the compatibility path.
Known response length remains checked as by OkHttp's complete-body API.

The body reference binds the native driver, request, source, runtime, installed
payload authority and original locator, with separate length/SHA-256/FNV/prefix
framing. It contains no caller-selected filesystem path. The host packet owner
atomically claims the raw file as a lease before cancellable off-UI integrity
validation; only verified leases are published to Dart.
The Dart body consumer opens one handle, makes bounded asynchronous reads and
joins admitted reads before closing and requesting release. Runtime/session
close also drains late replies and admitted body work; the original body
registration remains present until physical release acknowledgement. Unclaimed files are
removed by the existing packet/driver lifecycle; claimed files survive source
process loss and are released by the consumer. New host processes clear leases
left by a previous host process; clients in one process share a cleanup identity.

`SourceResourceTransport` alone converts the lease to its existing `ByteResponse`
contract, including image admission and matching Range validators. The response
stays staged/source-owned. `DownloadJob`/`DownloadSession` keep aggregation,
partial, promotion and artifact authority; transient filenames never enter a
persistent locator, DownloadId, trust or media identity. NetLane retains the
complete task lifetime and live control; no queue, retry, prefetch or eligibility
owner is added. Reader/native decode ownership and7/3/2/1 windows are unchanged.

## Consequences and acceptance

This delivery waits for sealed source output. It does not promise incremental
network delivery, earlier TTFB, lower source-interceptor cost or final-display
performance. Venera's complete-input transformation and unnegotiated clients
retain their existing contracts. Android cache files are transient and may be
evicted by the system; a missing/invalid file is an attempt failure, never READY.

Protocol, producer/consumer cancellation, physical retirement, integrity,
path confinement, legacy validator and Range checks precede full toolchain,
minified packaging and real-source device acceptance. Live streaming/pipe,
nonempty Cookie/POST, original loading and final presentation remain distinct
criteria. Evidence is in `docs/audits/mihon-sealed-body-delivery-2026-10-04.json`.

Actual Android Binder acceptance adds11 native body-lifetime cases and one
repository normal replay. Separate host/source processes transfer3.66MB and
14.52MB bodies with actual bind/unbind. Hash cancellation, admitted close,
source/producer death, session close, host restart and the original65-second
RPC timer pass; native fixtures preserve every exported user data field.
The temporary native transform fixture uses the common body owner and alone
does not prove Mihon's real HTTP cancellation or Dart consumer lifetime.
Evidence is in `docs/audits/runtime-body-binder-lifetime-2026-10-04.json`;
the remaining source variants and final display keep this decision Provisional.

Nine separate actual Dart MethodChannel/Binder/file-consumer cases and a
controlled replay now verify bounded1.10/4.02MB consumption, disposal/stream
cancellation/session close during pending real RAF Futures, and a claimed
consumer surviving source death/reactivation. Reads exit before the single
close/release. Adjacent replay backups preserve every non-creation data field.
This common consumer scope does not prove Mihon's real-origin HTTP cancellation,
the full SourceResourceTransport/Pipeline path or integrated runtime teardown.
See `docs/audits/runtime-body-Dart-consumer-lifetime-2026-10-04.json`;
the decision remains Provisional for its remaining acceptance.

Nine further device cases follow actual loopback HTTP through production rhttp,
source adapter and selected canonical/isolated SourceResourceTransport transforms
to the separate Service/Binder, claimed Dart file and ByteResponse. The1.61MB
output stays bounded to64KiB chunks; matching Range, mismatched validator,
discard-before-listen and actual unfinished-input TCP cancellation pass.
Nonempty synthetic Cookie/POST and source UA are observed at the real server;
they do not establish real-source CookieJar/client semantics. Production642
inputs remain unchanged, the full2280/Rust22 gate passes, and adjacent backups
preserve every non-creation field. This scope is counted separately from the
eleven native and nine earlier Dart consumer cases. Full transport/Pipeline
variants, integrated teardown, external-origin cancellation and the original
loading/display criteria remain open. See
`docs/audits/source-body-transport-2026-10-05.json`; status remains Provisional.
