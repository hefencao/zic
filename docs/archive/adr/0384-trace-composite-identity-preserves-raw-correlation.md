# ADR 0384: Trace composite identity preserves raw correlation

Status: Accepted

## Context

Trace payload provider-token redaction cannot delimit opaque tokens inside
length-framed composite keys. A manga ID with length 507 is reported as 511
when the regex consumes the next field's length, 1012. Its diagnostic hash
also changes, falsely suggesting a different identity. This does not prove
that any runtime identity, cache, URI or trust decision changed.

## Decision

At the TraceEvent JSON-safe normalization boundary, scopeId, physicalMediaKey,
providerExactId and candidatePhysicalKeys summarize the complete original key
when it is long or contains an opaque provider locator. Use the existing
stable hash and original length; recurse through candidate lists and normalize
nested map keys before selecting the diagnostic field contract. Repeated
normalization remains idempotent, and short ordinary values remain readable.

Telemetry does not parse domain framing or provider payloads. Standalone
comicId redaction and the public traceIdentityToken API remain unchanged.
No persisted identity, cache trust, source revision, URI, transport,
Reader/Pipeline ownership or scheduling policy changes.

## Validation

Two failing-first contracts expose the old length/hash corruption and cover
complete-key correlation, nested candidate lists, normalized map keys,
privacy and idempotence. Focused17 and the required toolchain gate2219/27
suites/Rust22 pass. Three-ABI Profile/ordinary Release, AOT and JNI/FFI proofs
pass; the installed ordinary Release and48-file production snapshot match.
Its9214-event one-click export independently matches127 long scopes against
the source catalog,11 provider exact keys and286 physical-key events against
the original raw backup; physical-summary lengths preserve the exact-key
framing relationship. Adjacent carriers absent from the old page backup do
not establish identity churn. Standalone comic summaries retain length507.

Correct Mihon lists, manual title/delete preview, five stationary sliders
including real chapter21 downloads and four chapter endpoints pass. The
original chapter19/20 report, specific shelf-admission device acceptance and
independent performance acceptance remain open. Two stale full-validation
links are reconciled to their already-passed referenced admission audit;
no production behavior is reverted to satisfy those outdated states.

Evidence: `docs/archive/audits/trace-framed-identity-sanitization-2026-10-03.json`.
