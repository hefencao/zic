# ADR 0028: Visible-frame readiness, authoritative artifact priming and external execution contracts

- Status: Accepted
- Version: `0.31.0-dev.44`

## Context

Three ownership gaps remained after dev.43. A durable store could implement both byte persistence and stable-file lookup, but Dart could not promote a nullable value to the intersection of two unrelated interfaces. Local WebP state treated container validation as presentation readiness. A cold Reader page could wait for a shared promoted-artifact read before the transport had started it. External plugin inspection also stopped before describing the exact payload and limits an isolated executor must receive.

## Decision

1. Introduce `ResourceCacheFileByteStore`, explicitly composing `ResourceCacheByteStore` with `ResourceCacheByteStoreFileAccess`. File-backed lookup and invalidation use only this aggregate capability.
2. Treat local WebP `ready` as a visible-frame event. Container validation remains internal to `NativeWebpPlayer`; the outer local-image state changes only after its renderer reports the first presented frame.
3. `PromotedArtifactReadPool` starts an exact cache read when the authoritative replacement `DownloadSession` enters `queued` or `receiving`. A page may join that read but cannot start cache/network demand. Promotion waiting checks state before and after listener registration.
4. Mihon metadata inspection returns normalized entry classes without loading classes. Source versus SourceFactory is resolved only after isolated loading. Missing executable entry metadata is a trust-gate denial.
5. Add separate Mihon and Venera execution-request contracts. Each carries the exact inspected payload and explicit timeout, response-size, concurrency and heap limits. Concrete APK and JavaScript engines remain isolated backend implementations.
6. Keep the existing Home startup trace but add no new startup work while the delay is not reproducible.

## Consequences

- Product code no longer relies on invalid interface-intersection promotion or nullable casts.
- Ready-state tests and UI state correspond to pixels presented, not merely bytes parsed.
- Cold promoted artifacts cannot deadlock waiting for a transport-owned read to begin, while demand ownership remains unchanged.
- Mihon and Venera compatibility can proceed independently without letting an engine re-download or substitute a payload after trust approval.
- This ADR does not claim that APK class loading or JavaScript execution is implemented.
