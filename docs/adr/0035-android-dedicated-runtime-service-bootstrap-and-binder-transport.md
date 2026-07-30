# ADR 0035: Android dedicated runtime service bootstrap and Binder-safe transport

- Status: accepted
- Version: `0.31.0-dev.51`

## Context

The dev.50 endpoint owned process generations and runtime sessions in Dart, but Android still returned a native `runtime-backend-unavailable` stub. There was no actual second process, no secondary FlutterEngine entrypoint, and no transport capable of carrying binary runtime responses without exceeding Binder's transaction limit.

## Decision

Declare a non-exported Android Service in `:zic_plugin_runtime`. The Service creates a FlutterEngine with automatic plugin registration disabled and executes a retained secondary entrypoint from the App's Dart main library. That entrypoint attaches `AndroidExternalPluginRuntimeServiceHandler` to a new `ExternalPluginRuntimeServiceEndpoint`.

The main process binds lazily and forwards each runtime method exactly once with a correlation ID. Service disconnect or Binder death fails outstanding requests; the client does not replay them or transparently reactivate a plugin. A later explicit activation may bind a new service and receives a new Dart `processId` generation.

Requests are restricted to a small inline StandardMessageCodec envelope. Responses below the inline threshold return in Binder. Larger responses are encoded once into an app-private atomic packet file; Binder carries only its path and length. The host validates that the canonical path is under the dedicated packet root, validates the exact length, reads it, and deletes it. No base64 expansion is introduced. The service clears only the dedicated packet root on startup/destruction and schedules bounded deletion for unclaimed large responses.

The production service starts with no runtime driver factories. Activation therefore reaches the dedicated process but fails closed with `driver-unavailable`. Kotlin owns only process/engine bootstrap and transport; payload verification, driver selection, session ownership, cancellation and close remain in Dart.

## Consequences

- The runtime code now executes in a distinct Android process before concrete Mihon or Venera engines are added.
- App-process crashes and service-process deaths have explicit request failure semantics and no implicit replay.
- Binary resource responses are not constrained by Binder's approximately one-megabyte transaction envelope.
- The secondary Dart entrypoint must remain reachable in AOT builds; the App main library contains a retained wrapper.
- Concrete APK class loading and JavaScript evaluation remain separate driver work and cannot bypass the process host.
