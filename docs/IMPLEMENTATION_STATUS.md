# Implementation Status

## 0.2.0-dev.2 — Download foundation and naming cleanup

### Naming

Internal code no longer repeats the product name where the repository already provides context:

```text
apps/app
packages/domain
packages/library
packages/reader
packages/pipeline
packages/sessions
packages/transport
packages/storage
packages/telemetry
packages/testkit
packages/bridge
native/media_core
```

Public Dart names were shortened where the meaning remains clear:

```text
ContentId / DownloadId / DecodeId / ResourceId
ReaderObs / Interaction / Coverage
SessionCoordinator / FakeSessionCoordinator
MonoClock / DetScheduler / Failure
```

The `zic_*` prefix remains on C ABI exports because those symbols share a global native namespace.

### Implemented in this iteration

- `ByteRange`, `Validators`, `ByteResponse`, and `Transport`.
- `HttpTransport` with `Range`, `If-Range`, ETag, Last-Modified, and Content-Range parsing.
- `FileTransport` with validator-aware ranged reads.
- WebP/GIF/fallback content signature sniffing.
- Streaming CRC32.
- Durable partial `Artifact` with strict contiguous append.
- Sidecar metadata write/read.
- Partial restore and checksum rebuild.
- Seal with length/checksum validation.
- Same-filesystem partial-to-final promote.
- `DownloadState` and immutable `DownloadSnapshot`.
- Exclusive `RunLease` for active transport and `WriterLease` for byte authority.
- Stale run/writer/epoch rejection.
- Detach without cancelling an active receiving writer.
- Safe reset, dispose, and eviction guards.
- `DownloadJob` with matching-validator resume.
- Discard rejected responses, then restart from zero when range or validators are rejected.
- Promote an already complete restored partial without another request.
- Trace events for state, committed bytes, resume, seal, promote, and rejected work.

### Tests added

- Standard CRC32 vector.
- Arbitrary chunk boundaries.
- Non-contiguous append rejection.
- Durable partial restoration.
- Exclusive writer ownership.
- Late old-epoch append rejection.
- Detach-retain behavior.
- Interrupted download resume.
- Validator mismatch restart.
- File transport range behavior.
- HTTP range and validator parsing.
- WebP/GIF signature sniffing.

### Validation state

The repository validator passes package boundaries, naming policy, manifest/resource integrity, Dart delimiter checks, and ABI symbol agreement.

The execution image still lacks Flutter/Dart and Rust toolchains, so analyzer, Dart tests, Flutter tests, and Cargo tests are configured in `tool/check.sh` and CI but cannot be claimed as executed locally.

### Deliberately deferred

- SQLite cache index and startup orphan scanner.
- Real coordinator network lane and cancellation tokens.
- Rust Animated WebP source/cursor/frame API.
- Platform texture path.
- Adaptive policy.

### Next iteration

1. Add cache records and SQLite-backed index.
2. Add artifact startup scanner with active-path protection.
3. Add a real download registry and network lane.
4. Connect download demand apply/detach to `DownloadSession` without letting UI own transport.
5. Add fault-injection tests for process interruption around seal/promote.
