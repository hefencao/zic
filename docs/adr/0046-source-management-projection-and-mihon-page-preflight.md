# ADR 0046: Classify enabled sources and preflight synthetic Mihon galleries

Status: Accepted in `0.31.0-dev.62`.

The source-management and synthetic-gallery validation decisions remain active. Any later use of ordinary chapter-body loading to fill unknown page-count labels was superseded by ADR 0062.

## Context

The dev.61 external-plugin screen interpreted “installed / repository” as two
simultaneous columns. That made the device-extension refresh action compete with
repository loading and put language folding in the repository, even though the
actual duplicate language entries appear in the enabled source list.

Mihon chapter compatibility also treated a fully empty chapter catalog as enough
to expose a synthetic `正文` chapter with `pageCount = 0`. Reactive return types
not recognized by the host, or a failed page-list candidate following an empty
candidate, could therefore be hidden as a valid-looking one-chapter comic.

## Decision

1. The root source-management projection classifies active sources into Native,
   Mihon and Venera sections. Mihon source language variants are grouped there;
   the preferred/common source remains visible and alternatives are collapsed.
2. Mihon and Venera installation screens use mutually exclusive Installed and
   Repository tabs. Device Mihon discovery belongs only to Installed and owns an
   independent refresh/error state.
3. Source ordering remains durable. Native and Venera sources reorder inside
   their sections; a Mihon language family reorders as one unit.
4. Mihon async adaptation recognizes Future, RxJava 1 blocking wrappers and
   RxJava 2/3 blocking terminals. A real exception from chapter/page discovery
   is never converted into authoritative emptiness.
5. A synthetic Mihon gallery chapter is exposed only after its page-list path
   has returned at least one page. The verified page count is carried in the
   detail response. Zero at catalog time means “unknown”, not a confirmed empty
   chapter.

## Consequences

- Plugin installation identity and source-language presentation remain separate.
- Repository lists no longer collapse installable variants; users choose exact
  APK/script records there.
- Broken chapter adapters now produce diagnostic failures instead of silent
  single-chapter placeholders.
- Gallery detail loading may perform one page-list request to validate the
  synthetic chapter before it is shown.
