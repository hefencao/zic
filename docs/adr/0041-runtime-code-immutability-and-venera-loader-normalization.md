# ADR 0041: Runtime code immutability and Venera loader normalization

- Status: Accepted
- Version: `0.31.0-dev.57`

## Context

Android 14 and newer reject dynamically loaded dex/APK files when the code file remains writable. The existing Mihon workspace was process-private and digest-verified, but its copied `extension.apk` inherited writable permissions, so activation failed before any extension entry was inspected.

Venera sources expose two pagination families: numbered `load(..., page)` and cursor-based `loadNext(..., next)`. Capability detection only recognized `load`, so a valid e-hentai source was rejected during activation. Catalog covers are ordinary HTTP(S) URLs, while the resource adapter previously accepted only transient chapter-page tokens. The protocol also leaked the non-domain direction value `topToBottom`, and source-key inspection scanned every lexical `key` assignment, including Picacg method locals.

## Decision

1. Stage each Mihon APK through a same-directory temporary file. Open the temporary file for writing, immediately remove all path write permission, then write through that already-open descriptor, flush and fsync, verify exact length and SHA-256, atomically rename to the runtime filename, reassert read-only state and verify again before constructing the class loader.
2. Normalize Venera loaders through one predicate that accepts `load` or `loadNext`. For cursor loaders, retain bounded runtime-local pagination state by source operation and arguments; page one resets state and subsequent pages consume the returned `next` token.
3. Allow `loadResource` to consume either an approved runtime token or an absolute HTTP(S) URL. Direct cover requests use the same network, cookie, DNS, response-size, retry and optional image-hook boundary as page resources.
4. Emit `vertical` from native adapters. Accept a bounded set of legacy direction aliases at the Dart protocol boundary and reject all unknown values.
5. Inspect only the first class-level literal `key` following a `ComicSource` class declaration. Preserve repository-to-script mismatch validation, but ignore method-local identifiers.
6. Normalize response headers from `Map<*, *>`, accepting both nullable Android URLConnection maps and non-null OkHttp maps while dropping invalid keys rather than relying on invariant generic assignment.

## Consequences

- Mihon code remains immutable at the moment Android loads it, while payload integrity, per-activation workspaces and cleanup semantics remain unchanged.
- Current Venera `loadNext` sources activate and paginate without source-specific Presentation code.
- Covers and details use the existing cache/resource pathway rather than a parallel downloader.
- Compatibility aliases are isolated at the wire-to-domain conversion boundary.
- Static inspection remains non-executing without producing false key conflicts from source implementation details.
