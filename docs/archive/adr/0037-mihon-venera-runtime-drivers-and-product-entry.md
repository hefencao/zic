# ADR 0037: Mihon/Venera runtime drivers and product entry

- Status: Accepted
- Version: `0.31.0-dev.53`

## Context

The dedicated Android service, Binder generation/death handling, process-private payload staging and protocol-v1 source adapter were complete, but production intentionally registered no ecosystem drivers. Adding repository buttons without executing actual APK/JavaScript payloads would leave the mainline unresolved, while implementing compatibility in Presentation would violate source, cache, download and Reader ownership.

## Decision

1. Register two process-local native driver factories from the existing Dart service entrypoint. Dart remains authoritative for inspection, trust, immutable staging, session identity, cancellation, limits and shutdown.
2. Load Mihon extensions only from the process-private verified APK copy with `DexClassLoader`. Discover approved `Source`/`SourceFactory` entries and reflectively adapt current 1.6 suspend calls plus legacy Rx calls to browse, comic, chapter and resource protocol operations. Reuse the source-owned HTTP client/headers when present.
3. Execute Venera sources in a process-private WebView with file/content access, DOM storage, cache and windows disabled. Supply a bounded Venera 1.6 compatibility surface for network, cookies, private storage, conversion, HTML parsing, compute and image manipulation, including array/object/`Map` result shapes used by deployed sources. Reject newer declared host requirements or unsupported operations explicitly.
4. Put repository download, immutable payload promotion, explicit user trust, pin persistence, update rollback and removal in `plugin_host_bridge`, not `apps/app/lib`. Presentation only displays repositories and activated sources.
5. Accept Mihon's current `index.pb` and `repo.json` repository entry URLs, but parse the full JSON companion published beside the protobuf index. The catalog accepts both the current `extensionList.extensions` v2 object and the legacy flat array. This keeps repository discovery compatible without introducing protobuf into the executable-plugin boundary or falling back to the obsolete minimal JSON upgrade sentinel.
6. Inject activated sources as ordinary `BrowsableComicSource` values. They receive no navigation, Reader demand, download-session, artifact or cache authority.

## Consequences

- Mihon APK and Venera JavaScript compatibility is executable rather than metadata-only, while untrusted code remains outside the main process.
- Ecosystem dependencies are runtime-only; the bridge reflects over the upstream ABI so the baseline Kotlin compiler does not consume newer upstream Kotlin metadata.
- Plugin restoration happens after the existing durable core service stages, preserving the established Home startup trace.
- Device/Gradle validation against real current extensions remains required in an Android toolchain; incompatibilities must fail with an attributable activation/operation error rather than empty content.
