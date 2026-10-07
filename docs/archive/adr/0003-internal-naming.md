# ADR-0003: Internal naming without repeated project prefixes

## Status

Accepted.

## Decision

The repository name already establishes product context. Internal packages, folders, Dart libraries, and Dart types therefore do not repeat `zic` unless a global namespace requires it.

Use concise names such as `domain`, `transport`, `Artifact`, `DownloadId`, and `ReaderObs`.

Keep `zic_*` for exported C ABI symbols and other process-global identifiers where collision avoidance is required.

## Consequences

- Imports and public APIs are shorter.
- Refactors and stack traces contain less visual noise.
- Generic names remain scoped by package boundaries.
- Native ABI names retain stable collision-resistant symbols.
