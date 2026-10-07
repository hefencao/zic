# ADR 0057: Pipeline runtime construction and presentation boundary

Status: Accepted in `0.31.0-dev.73`.

## Context

The dev.72 ownership split moved download, artifact, decode and upload runtime into `pipeline_runtime`, but several implementation types and platform choices remained referenced from presentation files. The incomplete migration caused compile failures and risked rebuilding coupling through convenient imports.

## Decision

- `PipelineReaderSessionFactory` requires an abstract `SourceFactory`.
- `pipeline_runtime` does not depend on the FFI `bridge` package.
- `local_media_ui` supplies the platform `NativeSourceFactory` and derives factories immutably when adding cache, byte-loader or local transport composition.
- Presentation obtains canonical page identity from `PipelinePageStream.identity`.
- Transport content sniffing is mapped to `PipelinePageContentKind` before it reaches presentation.
- Measured page geometry is a frame-coalesced Reader layout projection only.

## Consequences

The Pipeline core remains platform-neutral and testable, while Android/native composition stays explicit. UI packages cannot regain download/cache ownership through identity helpers or cache implementation types. Existing Venera streaming, prefetch and scheduler policy is unaffected.
