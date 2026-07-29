# ADR 0029: Versioned external runtime protocol and shared source adapter

- Status: Accepted
- Version: `0.31.0-dev.45`

## Context

The dev.44 execution requests described trusted payloads and resource limits but still allowed each future Mihon or Venera backend to return an arbitrary zic plugin session. That would duplicate catalog/domain mapping, make protocol drift likely and risk leaking Reader or artifact ownership into executable plugins. The external validation report also showed that a `Duration` relational assertion inside a const limits constructor prevented every plugin-host test from compiling.

## Decision

1. Keep `ExternalPluginRuntimeLimits` const-capable, but validate duration positivity when an executor/session activates. No executable backend receives invalid limits.
2. Define protocol version 1 with four operations: browse, load comic, load chapter and load binary resource. Permit only bounded, method-channel-safe scalar/list/map/`Uint8List` values.
3. Require Mihon and Venera backends to return an `ExternalPluginRuntimeConnection` containing runtime source descriptors and request/response invocation. Backends do not construct zic domain or Reader objects.
4. Use one `ExternalPluginRuntimeSession` to namespace source IDs, adapt protocol results to `BrowsableComicSource`, and validate request, source, comic, chapter and page identity.
5. Re-enforce timeout, response bytes and actual concurrency in the host. A caller timeout ends its wait but retains the permit until the underlying operation completes. FIFO permit transfer cannot be stolen by a newly arriving invocation.
6. Closing a session rejects queued work, signals the isolated connection, drains actual active operations and is joinable by concurrent callers.
7. Preserve Home startup trace unchanged while its prior delay remains unreproduced.

## Consequences

- Mihon and Venera engines can evolve independently behind one conformance surface without duplicating zic catalog mapping.
- Plugins cannot receive navigation, Reader, demand, download-session, cache-maintenance or artifact authority through the runtime protocol.
- Backend claims are not trusted as the only timeout/response/concurrency enforcement.
- This ADR does not implement Android APK class loading or JavaScript evaluation; those remain isolated protocol backends.
