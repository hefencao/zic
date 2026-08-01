# ADR 0044: Venera authentication, asynchronous Home recovery and Reader streaming ownership

## Status

Accepted in `0.31.0-dev.60`. Reader direct-source/cursor ownership was superseded by ADR 0061 in `0.31.0-dev.77`.

## Context

Venera source settings existed, but the source `account` contract had no product
mapping. Mihon combined detail could omit chapters even when a separate chapter-list
API contained a real multi-chapter catalog. App startup blocked the first usable Home
surface on durable library recovery. Reader scale recognizers competed with remote
page navigation, static media exposed animation controls, and remote WebP waited for
a final file rather than consuming the existing incremental download source.

## Decision

- Add normalized source-account operations to the external runtime protocol and map
  Venera account descriptors to `AuthenticatableComicSource`. Flutter only mediates
  user input and WebView interaction; the isolated runtime validates callbacks,
  writes Cookie/localStorage/account state and performs logout.
- Treat Mihon embedded chapters as one candidate, not an authoritative absence.
  Probe compatible chapter APIs across detailed/original manga objects and synthesize
  a gallery chapter only after the complete normalized result is empty.
- Mount a usable in-memory App composition immediately. Open durable services in the
  background, show non-modal sync state and swap composition after readiness.
- Install page-local zoom recognition only after explicit zoom. At scale 1 the
  `PageView` owns horizontal drag. Animation controls require media animation
  capability.
- Bind remote WebP native cursors to `DownloadSession.ingress.source`. Wait for
  committed-byte advancement on `needMoreData`; project restored-prefix and current
  network progress without adding another transport or cache owner.

## Consequences

The login UI can evolve independently of source persistence, gallery compatibility no
longer destroys real Mihon catalogs, Home becomes usable before durable recovery,
remote paging and zoom have a deterministic gesture owner, and streaming playback
shares the existing download/artifact lifecycle. More device validation is required
for source-specific Web login and long partial Animated WebP files.
