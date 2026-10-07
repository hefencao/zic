# Venera transform output uses the original body owner

Status: Provisional

## Context

Host input still requires a complete source transform. Both transform planes
also returned complete arrays through the runtime channel. A source-only body
capability would be rejected: the request schema disallowed bodyDelivery on
transformResource and the platform accepted only Mihon loadResource authority.
This is a carrier integration gap, not proof of the intermittent19/20 defect.

## Decision

Negotiate transform-output body delivery separately from source loadResource.
Both the source descriptor and connection must support it. Keep complete input,
onResponse and the canonical single-context semantics. Isolated-qualified
modifyImage remains on the same two workers and writes Bitmap.compress directly
into the original RuntimeServicePacketFiles body transaction. Canonical output
retains its JavaScript byte contract and is sealed by that same file owner.

Bind the original invocation, source, runtime, payload and locator. The platform
accepts only the negotiated operation and corresponding authority revision.
SourceResourceTransport shares the existing staged/source image, Range,
legacy validator and disposal contract with other sealed bodies. It owns no
new bytes, cache, scheduler, retry, eligibility or pipe policy.

A worker completion holds its output disposal callback until delivery. Cancel,
close and replacement discard unclaimed output. Encoding stays within the
original physical primitive and cancellation checks the same request. Driver
close joins existing physical work before retiring its unclaimed files.

## Verification and limits

The new protocol test fails against the pre-change request schema and passes
with explicit transform body delivery. Focused source/channel/transport tests
cover capability negotiation, canonical fallback, binding, cancellation,
legacy validators, Range and the existing five-plan semantic budget.

Required2276 Dart/Flutter and22 Rust checks,108 Android units and three-ABI
Profile/minified Release packaging pass. The same device fixture finds old
canonical/isolated negotiated output still returned arrays; new production
returns922147-byte sealed PNG, byte-exact with legacy output and pixel-exact
with rotation. Claims survive driver close and release removes their files.
Held encoder cancel/close and caught limit failure publish no body, leave no
partial file and settle once after physical exit. Baseline held fixtures cannot
enter the absent injection method and do not prove an old lifetime defect.
The initial missing-browse fixture activation failure is excluded.

Ordinary Release08709052/642 inputs passes six cached19/20 stationary slider
and boundary steps with119 cache reads and no download/failure. Both1s/6s
screenshots show source content or a source footer, rather than loading.
Ordinary JM chapter6 explicitly reloads page3: native input19492 bytes becomes
243063-byte output through the real two-process production sealed-file path.
This is the only download in that trace; there are no task failures. Same-process
route reentry reads10 cached bodies with no downloads/failures and page3 content
at1s/6s. This route reentry does not prove process-cold behavior. All120 complete
chapter records, including URIs/pages/importedAt, and six other persistent domains
remain exact; only three normal reading progress records change.

Actual Binder acceptance verifies11 native cases plus the repository normal
replay at3.66/14.52MB: byte/pixel equality, physical hash cancellation/close,
source/producer death, session close, host restart and the original65-second
RPC timeout. All642 production inputs were unchanged during this phase, and
the native fixtures preserve all eight exported data domains and120 chapters.
The restored process-cold Reader presents11 cached pages with no download or
failure, but history index2 drifts to3 without input; ADR0395 records that
separate geometry defect and its separate source change.

Nine independent Dart MethodChannel/Binder/file-consumer cases and a controlled
replay now verify bounded1.10/4.02MB consumption, pending real RAF retirement
on dispose/cancel/session-close and claimed source-loss survival. Single
close/release follow read exit; adjacent replay user data remains exact except
export time. This is direct Dart evidence, separately counted from the native
eleven cases in `docs/archive/audits/runtime-body-binder-lifetime-2026-10-04.json`.
See `docs/archive/audits/runtime-body-Dart-consumer-lifetime-2026-10-04.json`.

Host input collection and canonical internal whole-byte materialization remain.
Integrated real-origin cancellation, full SourceResourceTransport/Pipeline
variants and teardown, the original loading cause and final performance remain
unverified. Actual pending RAF Futures do not establish a long blocked kernel
read. This decision remains Provisional for the remaining scope.

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
