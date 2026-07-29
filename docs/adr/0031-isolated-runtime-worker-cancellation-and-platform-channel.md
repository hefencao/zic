# ADR 0031: isolated runtime worker, cancellation and platform channel

- Status: Accepted
- Version: 0.31.0-dev.47

## Context

Protocol v1 and the host-side source adapter established a common Mihon/Venera call surface, but an isolated backend still needed a common server-side owner. Without one, APK and JavaScript implementations could diverge on request validation, duplicate identities, error exposure, cancellation and shutdown. A host timeout also cannot be treated as proof that the underlying plugin call stopped.

## Decision

1. `ExternalPluginRuntimeWorker` owns protocol handling inside every isolated runtime. It reparses raw requests, verifies active source identity, rejects duplicate active request IDs, sanitizes failures and tracks the real driver Future.
2. Ecosystem drivers implement only `ExternalPluginRuntimeDriver`: source discovery, protocol operation dispatch, cooperative cancellation checkpoints and close. They receive no zic Reader, download, session or artifact objects.
3. Raw channels may implement `CancellableExternalPluginRuntimeMessageChannel`. Host timeout sends best-effort request cancellation, but the invocation gate retains its permit until the original Future exits.
4. Worker close is joinable. It stops admission, cancels active tokens, closes the driver and drains the captured active operations before completing.
5. Mihon and Venera activation messages include the exact inspected payload path, length and SHA-256, plugin identity, approved capabilities and complete runtime limits.
6. Android host adapters expose activation, invocation, cancellation and close over one method-channel contract. Until a dedicated isolated native service exists, activation fails closed; loading APK or JavaScript in the application process is forbidden.

## Consequences

- Both ecosystems share one conformance surface and one lifecycle implementation.
- Timeout cannot be used to bypass the declared concurrency limit.
- Backend stack traces and implementation details do not cross the protocol boundary.
- Actual Mihon `Source`/`SourceFactory` loading and Venera JavaScript evaluation remain separate drivers, but they cannot bypass payload, trust, capability, limit or teardown gates.
