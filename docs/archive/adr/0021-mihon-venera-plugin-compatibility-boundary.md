# ADR 0021: Mihon and Venera compatibility through isolated plugin hosts

## Status

Accepted as the compatibility boundary in `0.31.0-dev.38`. The shared
pre-execution trust/permission/session gate is implemented in `0.31.0-dev.39`;
ecosystem-specific APK/Kotlin and JavaScript executors are not yet implemented.

## Context

Mihon extensions and Venera comic sources use different runtime and packaging
models. Treating either format as a Flutter Widget plugin or importing its
execution model into `catalog` would let untrusted code bypass zic source
identity, navigation, Reader demand and download ownership.

Repository metadata is still useful before executable code is activated. zic
needs one format-neutral representation for displaying, validating and choosing
external source packages while preserving each ecosystem's native identities.

## Decision

1. `catalog` owns only immutable external plugin catalog metadata and parsers.
   It does not download, install, evaluate or execute plugin code.
2. Mihon repository entries preserve package name, APK entrypoint, extension
   version and each declared source ID as a string. zic source IDs use the
   `mihon:<external-id>` namespace so large numeric IDs are never converted
   through a lossy number representation.
3. Venera repository entries preserve the JavaScript entrypoint and version.
   The parser accepts both documented `filename` and deployed `fileName` spellings.
   When the repository declares `key`, zic immediately establishes `venera:<key>`;
   only keyless entries defer source identity discovery to the sandboxed script.
4. Executable integration must implement `ExternalComicPluginHost` and return
   an `ExternalComicPluginSession` with explicit `close()` ownership. The host
   is responsible for compatibility checks, trust/signature policy,
   permissions, sandboxing, cancellation and resource limits. A Mihon-compatible
   Android host must inspect extension APK metadata such as
   `tachiyomix.extensionLib` before class loading rather than assuming all APKs
   use the same extension ABI.
5. Activated external sources are adapted to ordinary
   `BrowsableComicSource` instances. They cannot inject routes, construct
   Reader controllers, inspect Reader state, own DownloadSessions or mutate
   artifacts directly.
6. Mihon APK/Kotlin hosting and Venera JavaScript hosting remain separate bridge
   implementations. Sharing catalog metadata does not imply sharing execution
   or permission models.

## Consequences

- Repository/index compatibility can advance without coupling zic core to an
  APK or JavaScript engine.
- Shared inspection, trust, permission, quarantine and active-session ownership are implemented without executing plugin code.
- Full plugin execution is deliberately not claimed by this iteration.
- A future Android Mihon host and cross-platform Venera JavaScript host can be
  tested and permissioned independently while producing the same zic catalog
  interface.
- Plugin lifecycle leaks and source-ID collisions have explicit architectural
  prevention points.
