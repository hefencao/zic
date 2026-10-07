# ADR 0045: Reader/media UI composition packages and ecosystem repository layout

Status: Accepted in `0.31.0-dev.61`.

## Context

`apps/app/lib/reader_runtime.dart` assembled media, pipeline, sessions, storage and transport directly, and missed the `media.SourcePool` import. `webp_demo.dart` exceeded 3300 lines and relied on WebP prefix helpers without an explicit owner import. The source manager also duplicated all installed external plugins above the ordinary source list, separate from the ecosystem repository where installation actually occurred.

## Decision

- Move Reader composition to `packages/reader_runtime`; App exposes a compatibility facade.
- Move local image/WebP presentation to `packages/local_media_ui`, split by state ownership, and import prefix parsing explicitly from `media`.
- Prohibit App production dependencies on pipeline/session/storage/transport when they are only needed by Reader composition.
- Put each ecosystem's installed projection and repository projection on the same screen, left and right respectively.
- Group Mihon language variants by package family for display only. Keep the preferred/common variant visible and collapse alternatives initially.

## Consequences

The App layer has fewer direct low-level dependencies and missing transitive imports become package-local compile errors. Compatibility exports preserve existing routes/tests. Plugin identity and trust remain per exact package; language grouping does not merge installation or activation state.
