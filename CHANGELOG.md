# Changelog

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
