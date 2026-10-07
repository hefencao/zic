# ADR 0027: compact cover manifest, Home startup trace and Android Mihon metadata bridge

- Status: Accepted
- Version: `0.31.0-dev.43`

## Context

The dev.42 file-backed cover path removed whole-file Dart copies on warm hits,
but every cover could still require its own metadata JSON parse. The external
compile report also exposed several unsound nullable/generic branches. Finally,
Mihon inspection had only a Dart interface, so Android APK package, signer,
version and extension ABI metadata could not be obtained by the real host.

## Decision

1. The durable response-byte store owns one versioned compact manifest loaded
   once per process. Per-entry JSON remains an atomic crash-recovery journal,
   not the normal warm-hit index. LRU touches stay in memory and are flushed as
   one manifest mutation on close or maintenance.
2. Home startup emits one monotonic trace for bootstrap presentation, service
   open phases, cover request, encoded-source readiness and first decoded frame.
   The trace is observational and cannot choose covers or cache policy.
3. Encoded resources carry an explicit origin (`memory`, `localFile`, or
   `durableCacheFile`) so startup traces do not infer origin from paths.
4. Android supplies `MihonApkMetadataReader` through a Flutter plugin. APK
   archive parsing runs on a dedicated worker, uses `PackageManager`, reads the
   current signer, version code and supported extensionLib metadata keys, and
   never creates a class loader.
5. Venera payload inspection reads its bounded immutable script once, deriving
   UTF-8 metadata and SHA-256 from the same byte snapshot without evaluation.

## Consequences

- A warm shelf performs one compact index read rather than one metadata parse
  per visible cover, while exact file length remains checked before handing a
  path to the engine.
- Startup delays can be attributed to service opening, cache/source readiness,
  or image decoding instead of being reported as one undifferentiated black
  interval.
- Mihon APK identity and ABI checks are concrete on Android, but extension code
  execution remains a separate permissioned executor.
- Venera remains bounded and non-executing; a JavaScript sandbox is still
  required before sources can be activated.
