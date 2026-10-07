# ADR 0022: Attributable Reader transitions and permissioned external plugin runtime ownership

## Status

Accepted in `0.31.0-dev.39`.

## Context

A stable Reader page host prevents an unnecessary media remount, but a later blank frame can still originate from
network fallback, artifact lookup, decode queueing, upload queueing, presentation, or an actual host disposal. Existing
trace events did not carry enough shared identity/revision information to distinguish those paths.

Mihon and Venera catalog metadata also cannot safely flow directly into code execution. The two ecosystems need
separate runtimes, while zic still needs one common place for pre-execution trust, capability, quarantine, source
identity and session-lifetime rules.

## Decision

1. Reader transition, page-current, page-host mount/dispose and first-frame events carry stable page identity and the
   relevant demand revision. Transition events include current/target coverage and logical position.
2. Artifact transport records whether bytes came from the promoted artifact tier or the origin transport. Decode and
   upload lanes record demand and actual start events. A demand retains the revision that created it while queued or
   waiting for source readiness.
3. These events are observational. Telemetry cannot create demand, retain a page, choose a prefetch window, bypass an
   artifact, decode a frame or upload a texture.
4. `plugin_host` owns the shared pre-execution gate. Inspectors may read metadata and hashes without executing plugin
   code. Executors are ecosystem-specific and receive code only after policy accepts inspection.
5. Mihon policy can gate repository origin, payload digest, package identity, signer digest, version/code floor,
   extension ABI and capabilities. Venera policy can gate repository/payload, required stable source-key discovery and
   explicitly allowed capabilities.
6. Activation failures may be quarantined. Returned sessions are identity-checked and explicitly closable.
   `ExternalPluginRuntimeRegistry` owns active sessions and rejects cross-plugin source-ID collisions after closing the
   rejected session.
7. This ADR does not implement or claim an Android APK/Kotlin class loader or a JavaScript engine/network bridge.

## Consequences

- Midpoint and rapid-swipe traces can distinguish a host remount from a cache miss, queued decode/upload or delayed
  first presentation without adding competing Reader policy.
- Plugin installation UI cannot bypass trust and lifecycle rules by calling an executor directly.
- Mihon and Venera can evolve separate sandboxes while sharing source identity and active-session invariants.
- Concrete executors, persistent trust settings, repository update signatures and migration UI remain later work.
