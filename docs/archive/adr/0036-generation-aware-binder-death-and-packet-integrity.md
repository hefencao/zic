# ADR 0036: Generation-aware Binder death and verified packet consumption

- Status: Accepted
- Version: `0.31.0-dev.52`

## Context

The dedicated Android runtime service existed, but the main-process client reused one `ServiceConnection` and boolean `binding/bound` flags. A delayed disconnect callback could not be attributed to a specific bind, and a bind that never completed remained permanently marked as binding after its callers timed out. Large response packets were constrained by canonical path and length but had no content identity after the isolated process wrote them. The reported `ExternalComicPluginFormat` failures also showed that service code and its entrypoint regression relied on an implicit catalog type rather than explicit imports.

## Decision

1. Give every explicit `bindService` attempt a monotonically increasing binding generation. The connection callbacks and Binder death recipient capture that generation; callbacks for retired generations are ignored.
2. Link to Binder death after connection and unlink on loss/cleanup. A service loss fails current pending and queued requests once, clears its packet state and never automatically replays or reactivates them.
3. If all callers time out before a connection is established, retire and unbind that binding generation so a future explicit activation can create a fresh one. Do not tear down a connected service merely because one request times out.
4. Represent response storage as a pure packet reference with exactly one inline/file form, exact length and SHA-256. File packets must remain under the canonical dedicated root and use the `.packet` suffix. Verify digest during the one required read into the platform codec buffer and delete on success or failure.
5. Import catalog-owned plugin format types explicitly in service code and tests; package visibility must not depend on unrelated transitive imports.

## Consequences

- Real process death is observed independently of ServiceConnection timing, and stale callbacks cannot destroy a newer explicit rebind.
- An unavailable/hung service does not permanently wedge the client binding state.
- Packet corruption or same-UID path tampering is detected before the response reaches Dart; validation adds one streaming SHA-256 pass without another file read or base64 expansion.
- A full Android instrumentation kill/rebind test remains required, but the generation state and packet file owner are now Android-free units with JVM regressions.
- Mihon class loading and Venera JavaScript evaluation remain separate fail-closed drivers.
