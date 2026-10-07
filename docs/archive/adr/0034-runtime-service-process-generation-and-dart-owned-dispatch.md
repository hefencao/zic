# ADR 0034: Runtime service process generation and Dart-owned dispatch

- Status: Accepted
- Version: `0.31.0-dev.50`

## Context

The host-side MethodChannel had operation names for Mihon/Venera activation and session traffic, while the isolated process host already owned payload verification and session state. Implementing an Android service directly in Kotlin would risk duplicating activation parsing, session registry, cancellation and teardown policy. Service restarts could also reuse a session ID and make a stale host connection target an unrelated new process.

## Decision

Introduce `ExternalPluginRuntimeServiceEndpoint` as the only process-side dispatcher. Platform code transports raw method names and basic wire values; the endpoint validates method fields and ecosystem agreement, then delegates to `ExternalPluginRuntimeProcessHost`.

Each endpoint creates a unique `processId`. Activation returns the process generation with the session ID and handshake. Invoke, cancel and close require both identities. A new process rejects the old generation before session lookup and never replays or transparently reactivates a request.

`plugin_host_bridge` provides a Dart MethodChannel service handler for a dedicated FlutterEngine. It maps sanitized endpoint/process failures to platform errors, but does not own payload or session policy.

## Consequences

- Kotlin/Binder/service bootstrap remains transport and process-lifecycle code rather than a second runtime state machine.
- Service death is explicit to callers and requires deliberate activation of a new session.
- Concrete Mihon class loading and Venera JavaScript evaluation remain separate drivers behind the same process host.
