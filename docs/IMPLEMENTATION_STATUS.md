# Implementation Status

## 0.3.0-dev.3 — Cache recovery and network lane

### Naming corrections

- Renamed the reserved internal package `library` to `catalog`.
- Renamed its entry library to `catalog.dart` and updated the App, workspace,
  benchmark, parser tests, CI, and repository validator.
- Renamed `SessionCoordinator` / `FakeSessionCoordinator` to
  `Coordinator` / `FakeCoordinator` inside the already-scoped `sessions`
  package.
- Renamed bridge locals to `lib` / `libPath` / `libVersion`.
- Added a repository gate rejecting the reserved package name `library`.

### Transport correction

`Validators.fromJson` no longer relies on promotion through a compound type
check and does not add a redundant `as String`. It branches explicitly:
null remains null, a String is parsed, and every other type is rejected.

### Cache and artifact lifecycle

- Added `CacheRec`, `CacheState`, and the async `CacheIndex` contract.
- Added `MemIndex` for deterministic tests.
- Added `SqliteIndex` with schema version 1, WAL mode, upsert, filtering,
  totals, and unsupported-version rejection.
- Added deterministic `CacheLayout` paths based on `DownloadId`.
- Added `CacheScanner` for metadata recovery, stale record removal, orphan
  cleanup, checksum rebuild, and active-path protection.
- Final artifacts now retain authoritative metadata instead of deleting all
  metadata during promote.
- Promote stages final metadata before moving bytes and recognizes
  `.meta.tmp` after interruption.
- `DownloadId` and `ContentId` now have explicit JSON representations.
- `DownloadSession` updates/removes cache records on restore, bind, seal,
  failure, promote, reset, and eviction.

### Real network execution

- Added bounded-concurrency `NetLane` with priority, FIFO tie-breaking,
  coalescing, queued cancellation, active cancellation tokens, and idle wait.
- Added `DownloadRegistry` as the sole owner of download sessions.
- Added `LiveCoordinator`, which maps download demand diffs to the network
  lane while retaining active receiving tasks after ordinary detach.
- Added cooperative cancellation to `DownloadJob` and response discard when
  cancellation arrives after open.
- Added `StartupRecovery` to open the index, scan artifacts, restore sessions,
  and emit one cache-scan trace event.
- Added `IoTransport` routing for HTTP(S) and file URIs.

### Tests added or adjusted

- Catalog package/import regression coverage.
- Validator parsing and invalid-type rejection.
- Memory and SQLite cache index parity.
- Partial/final scanner reconstruction.
- Interrupted-promote staged metadata recovery.
- Active orphan protection.
- Network lane priority, FIFO, coalescing, and queued cancellation.
- Live coordinator file download integration.
- Startup scan and session restoration.
- Final metadata retention after promote.

### Validation state

The local repository validator, YAML parser, manifest/resource checks, package
boundary checks, naming checks, delimiter checks, shell syntax checks, and ABI
symbol checks pass.

This execution image still has no Flutter/Dart or Rust toolchains. Therefore
`dart format`, analyzer, Dart/Flutter tests, Cargo formatting, and Cargo tests
remain CI gates and are not claimed as locally executed.

### Next iteration

1. Add cache capacity policy and LRU candidate selection without bypassing
   session safety checks.
2. Add explicit clear-cache orchestration and released-byte reporting.
3. Add retry/backoff policy for demanded failed downloads.
4. Add decode/upload lane shells before introducing the Rust WebP cursor API.
5. Begin the incremental Rust WebP byte-source contract and fuzzable parser
   boundary.
