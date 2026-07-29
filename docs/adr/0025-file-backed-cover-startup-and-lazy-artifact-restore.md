# ADR 0025: File-backed cover startup and lazy artifact restore

## Status

Accepted for `0.31.0-dev.42`.

## Context

After a process restart the Home screen could remain black for several seconds even though cover responses were present in the durable cache. Each warm cover still parsed a sidecar, read the complete encoded file into the Dart heap, recalculated a whole-file hash, rewrote and flushed access metadata, and then handed those bytes to `MemoryImage`. Plain local images followed the same whole-file byte path. Application bootstrap also opened storage and eagerly restored every indexed offline page before mounting the Flutter root.

## Decision

1. `ResourceCacheByteStoreFileAccess` exposes a validated immutable file location for complete encoded image responses. The byte-store contract remains available for non-file implementations and explicit byte consumers.
2. Cover presentation receives `EncodedResourceSource`. Warm durable covers use `FileEncodedResourceSource` and an engine-facing `FileImage`; network misses may arrive in memory once, are atomically persisted, and then resolve to that durable file.
3. File-backed warm hits validate key, expiry and length without a whole-file `readAsBytes` or hash on the startup path. Access-time touches are held in memory and flushed in a batch during store close. Atomic write/promotion remains the integrity boundary.
4. Ordinary local static images use a file provider when no Reader/pipeline loader or decode probe owns the request. Android `content://`, animated formats and Reader pages keep their explicit byte/session adapters.
5. `main()` mounts a Flutter bootstrap surface immediately. Durable services open after `runApp`; failure falls back to the existing in-memory composition rather than leaving the native window black.
6. `PersistentChapterDownloadService.open` opens the index only. Home read-state uses one bulk library query, and Home download badges use `inspectMany` over one cache-index listing without creating sessions or checking page files. The exact `DownloadSession` is materialized/restored only when a command touches that page.
7. “Zero copy” means no avoidable complete encoded-file copy into the Dart heap. Platform image decoders may still map or copy data internally; storage-to-texture absolute zero copy is not promised.

## Consequences

- Home warm-start cost scales mainly with visible metadata lookups and actual image decode, not with repeated whole-file Dart reads and hashes.
- Local static image presentation avoids a redundant Dart byte allocation.
- Large offline libraries no longer add one restore operation, file stat or SQLite query per cached page for initial Home projection.
- Byte-oriented consumers and Android content URIs retain controlled fallbacks without moving Reader demand ownership into Presentation.
