# ADR 0024: Direct promoted-artifact consumption and gapless target re-decode

## Status

Accepted for `0.31.0-dev.41`.

## Context

A durable Reader page artifact is already complete and promoted, but a reopened Reader previously waited for that file to be read into memory, copied through a new ephemeral `DownloadSession`, sealed/promoted again, and read back before decode could start. Large animated WebP pages therefore showed a long black interval even on a cache hit. A target-size change also disposed the currently presented Flutter frame before the replacement codec produced its first frame.

## Decision

1. `downloads.PromotedArtifactReadPool` starts the exact immutable read only from the replacement session transport and lets the page consumer join that read. Page construction cannot initiate cache I/O.
2. The Reader may begin decode from that already-promoted byte result immediately. The replacement `DownloadSession` still runs through transport, receiving, seal and promote; the pool does not create demand or choose retention.
3. Shared reads are released when the replacement session becomes promoted, failed or disposed, and on Reader shutdown.
4. Cache-to-session transfer is streamed in bounded chunks. Resume validators are derived from the exact `DownloadId` plus length; integrity remains the responsibility of the original promotion/storage path rather than a second whole-file hash on the UI isolate.
5. Cache read failure is fail-open: the page waits for the normal session while the transport falls back to origin and emits attributable failure telemetry.
6. A Flutter animated target-only rebuild keeps the last presented `ui.Image` until the replacement codec frame is presented. Encoded-byte identity changes still clear the old frame.
7. Telemetry reports durable artifact storage-read and Reader-join time plus consumer separately from decode/presentation time. Decoded frames are not persisted across process death, so a cold process still performs decode.

## Consequences

- A cache hit no longer serializes first-frame decode behind cache-to-ephemeral copy and re-read.
- Pipeline/session ownership remains authoritative and Presentation gains no private page cache or warmup policy.
- Large background handoff is cooperative rather than one giant stream chunk.
- Remaining cold-open latency can be attributed to durable read versus codec work instead of being described generically as a cache miss.
