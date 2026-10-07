# ADR 0059: Contract ownership, compatibility removal and test placement

Status: Accepted in `0.31.0-dev.75`.

## Context

The dev.74 compile report exposed several migrations that were structurally complete in production but incomplete at package and test boundaries. App tests still referenced Pipeline/download internals, a dead local-details compatibility screen converted cached presentation back into a separate callback contract, and `AssetBundleTransport` tests lived in the App package even though the implementation is private to `pipeline_runtime`.

## Decision

- Tests for an implementation live in its owning package. `AssetBundleTransport` is tested under `packages/pipeline_runtime/test` and is not exported through App or Reader compatibility facades.
- Domain-owned models are imported from `domain`; packages do not broaden exports merely to hide a missing import in a test.
- Reader setting extensions require an explicit extension-library import.
- App media tests do not call `readerPageDownloadId`; downloads owns and tests canonical download identity.
- The unused `ComicDetailsScreen` compatibility wrapper is removed. App details tests exercise `LocalComicDetailsScreen`, the actual lifecycle owner, and consume `EncodedResourceSource` rather than a byte-only cover callback.
- Compile-migration gates may verify dependency and API placement, but they do not replace Dart analyzer or Flutter tests.

## Consequences

The App package has fewer compatibility surfaces, package tests follow dependency ownership, and future API moves must migrate every caller rather than preserve a misleading facade. Production behavior, Pipeline preload windows and media lanes remain unchanged.
