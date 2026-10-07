# ADR 0026: Immutable Mihon and Venera payload inspection

## Status

Accepted for `0.31.0-dev.42`.

## Context

The plugin host already enforced repository, payload, signer, ABI, capability, quarantine and session gates, but it had only abstract inspectors. A compatible implementation needs to inspect the exact downloaded APK or JavaScript payload before execution, without downloading it twice or running untrusted code during metadata discovery.

## Decision

1. `ExternalPluginPayloadLoader` returns one stable immutable local payload file with declared length. Download, atomic promotion and retention remain adapter responsibilities.
2. Inspectors verify the actual file length and stream SHA-256 from the file. The approved `ExternalPluginInspection` carries the same path and length to the executor, so activation does not reacquire a different payload.
3. `MihonApkInspector` delegates package name, signer digest, version code and extension ABI extraction to `MihonApkMetadataReader`. The Android adapter must inspect package metadata only and must not create a class loader during inspection.
4. `VeneraJavaScriptInspector` enforces a bounded script size and performs metadata-only lexical source-key discovery. It never evaluates the script. A repository key and script key must agree.
5. Existing trust and capability policy remains the authorization boundary after inspection. Concrete Kotlin/APK and sandboxed JavaScript executors remain separate adapters with explicit session teardown.

## Consequences

- Mihon and Venera compatibility now has concrete pre-execution payload inspectors rather than only mocks.
- Payload identity is stable across inspection and execution.
- APK hashing is streaming and does not materialize the archive in the Dart heap.
- JavaScript discovery is deliberately conservative; scripts requiring dynamic key computation remain rejected until the sandboxed runtime adapter exists.
