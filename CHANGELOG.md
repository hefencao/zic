# Changelog

## 0.3.0-dev.3

- Renamed the reserved `library` package to `catalog` and updated all imports, workspace entries, tests, CI, and validation.
- Reworked Last-Modified JSON parsing without an unnecessary cast.
- Added cache records, memory/SQLite indexes, deterministic cache layout, startup scanning, orphan repair, and active-path protection.
- Preserved final artifact metadata and added staged metadata recovery around atomic promote.
- Added `NetLane`, `DownloadRegistry`, `LiveCoordinator`, cooperative cancellation, and startup session restoration.
- Added cache/index/scanner/lane/coordinator/recovery tests.

## 0.2.0-dev.2

- Removed redundant `zic_` prefixes from internal packages, folders, imports, and public Dart types.
- Shortened core types to `ContentId`, `DownloadId`, `DecodeId`, `ResourceId`, and `ReaderObs`.
- Added `transport` with HTTP/File byte streaming, range requests, validators, and signature sniffing.
- Added `storage` with durable partial artifacts, CRC32, metadata, seal, reset, and promote.
- Added `DownloadSession`, exclusive `RunLease`/`WriterLease`, epoch rejection, detach-retain semantics, and safe eviction checks.
- Added `DownloadJob` with resumable transfer and validator-mismatch restart.
- Added interruption, stale writer, arbitrary chunk, range, HTTP, and file transport tests.

## 0.1.0-dev.1

- Created the monorepo baseline.
- Added the first 100-page local static reader vertical slice.
- Added reader observation, role window, heuristic demand planning, policy guard, demand diff, fake coordinator, trace schema, testkit, and Rust ABI smoke surface.
