# Native runtime close joins physical work

Status: Provisional

## Context

Normal Venera invocation completion already joins JavaScript and native async
work. Its close path still cleared pending results and recycled images while
native HTTP or synchronous image work could be executing. Isolated transform
close had the same race. Mihon close could acknowledge after a five-second
wait while its invocation continued. Host removal also let a repeated close
acknowledge early, and a late activation could escape host teardown.

## Decision

Register admitted physical work in each existing owner. The registration has
no executor, queue, capacity, priority or retry policy. Close fences admission
and returns a shared `closeWhenDrained` Future. Native calls retire in their
physical exit path; resource cleanup and pending close results follow that
boundary. Destroy the WebView on Main after native work drains.

The host keeps its existing driver map until physical close and retains the
lifetime registration of activations, including a driver arriving during
teardown. Mihon cleanup stays on the original worker. Service teardown retains
the engine needed by resolver callbacks, then drains the original IPC
executors and their Main callbacks before clearing packet files.

## Consequences and verification

Main remains available to resolver callbacks. No source HTTP, cache identity,
trust, network capacity, invocation capacity or Reader ownership changes.
The old production close body with controlled blocked work fails, and the same
probe on the actual baseline APK fails four close boundaries. The current APK
passes five scoped native close cases and prior normal/cancellation cases.
All 2259 Dart/Flutter tests, Rust22, Android103 and three Profile/Release ABIs
pass. The ordinary Release cached19/20 smoke passes with108 cache reads and no
download/failure; all120 complete chapter payloads remain exact.

The same added integration probe fails the old APK and passes the current APK
for production engine/rhttp cancellation, original IPC executor fences and
both real isolated WebView workers. The Service fixture manually attaches the
production class in the instrumentation process and holds a loopback body;
it does not invoke Android bind/unbind or the isolated-process lifecycle.
Worker success includes actual decode, rotation, encode and finish before the
held native primitive/close case. No additional production change was needed.

Actual Android binding and common body-carrier lifetime are now independently
verified by11 native cases and one repository replay: large cross-process
claims, physical hash cancel/close, source/producer death, session close, host
restart and the original65-second RPC timeout. This is additional scoped
evidence, not a reinterpretation of the manually attached earlier fixture;
see `docs/archive/audits/runtime-body-binder-lifetime-2026-10-04.json`.
Nine actual Dart channel/Binder/file-consumer cases and a controlled replay
add bounded large-body reads, pending RAF disposal/cancel/session-close and
claimed source-loss survival. All admitted reads exit before single RAF close
and native release; adjacent replay exports preserve every non-creation field.
The evidence is separate from the eleven native cases, in
`docs/archive/audits/runtime-body-Dart-consumer-lifetime-2026-10-04.json`.
Status stays Provisional for real-origin HTTP cancellation, complete
SourceResourceTransport/Pipeline variants and integrated runtime teardown.
Observed native exit and WebView
destroy do not establish renderer physical exit. The original chapter19/20
loading cause and final display performance remain open.

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
`docs/archive/audits/source-body-transport-2026-10-05.json`; status remains Provisional.
