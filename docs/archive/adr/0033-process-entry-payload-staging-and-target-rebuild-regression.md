# ADR 0033: Process-entry payload staging and meaningful target-rebuild regression

- Status: Accepted
- Version: `0.31.0-dev.49`

## Context

The gapless Flutter animation regression changed a 2×2 WebP container from 320 to 180 logical pixels and assumed this must rebuild the codec. The raster policy correctly keeps a source-sized decode for tiny images, so no target change occurred and the test timed out waiting for a second codec activation.

External plugin payloads were inspected and hashed in the host process, but a future isolated driver would still reopen the original path. A mutable or replaced path between inspection and class-loader/JavaScript startup would create a verify-then-use race. The platform channel also needed one explicit process-side owner for session registration and restart semantics.

## Decision

1. The animation regression uses a deterministic VP8X fixture that declares a 2048×2048 canvas while retaining the fake codec. It records target dimensions and requires at least two distinct downsample targets before asserting that the previous frame remains visible.
2. Raw Mihon/Venera activation messages are reparsed inside the isolated boundary with exact schema fields, format-specific plugin identities, capabilities and runtime limits.
3. The process verifier rejects non-regular payload paths, streams the approved payload into a process-private partial file, recomputes SHA-256 and byte length, flushes it, and atomically promotes the verified copy.
4. Ecosystem driver factories receive only the process-private verified payload. The process session owns that file until worker shutdown and then deletes it.
5. `ExternalPluginRuntimeProcessHost` serializes activation, owns the session registry, routes invoke/cancel/close, validates Venera source-key discovery, and starts empty after process restart. It never replays an interrupted request. Closing drivers continue to consume a session slot, and process shutdown rejects and drains in-flight activation instead of publishing a doomed session.

## Consequences

- A viewport change that does not alter the raster target remains a valid no-op rather than a false failure.
- APK/JavaScript drivers cannot bypass process-entry identity verification by reopening a host-controlled path.
- Activation performs one deliberate payload copy inside the isolated process. This security copy is separate from image zero-copy goals and occurs only when activating external executable content.
- Android service and isolate implementations can share one session/restart contract, while concrete Mihon class loading and Venera JavaScript evaluation remain separate fail-closed drivers.
