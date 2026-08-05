# ADR 0004: Local-media import boundary

## Status

Accepted for the current `0.18.3-dev.21` candidate.

## Context

Folder import previously placed image models, recursive `dart:io` enumeration,
header sniffing and Android bridge adaptation in `apps/app/lib`. That made the
Flutter application layer own platform storage policy and allowed the Reader UI
to become coupled to filesystem details. Android single-file import and folder
import also used different access semantics: a selected file was readable via a
content resolver, while a selected directory could be treated as a raw path.

## Decision

- `packages/local_media` owns local-image models, file-header sniffing, desktop
  recursive enumeration and the platform-selection facade.
- `packages/local_media_bridge` owns Android document-tree selection and content
  URI byte access only.
- `apps/app` owns presentation, route state and user interaction. The former
  `local_image_folder.dart` compatibility export had no production caller and
  was removed in dev.136; App imports the owning packages directly.
- Android folder candidates are recognized by header first, then provider MIME
  and filename metadata. A failed probe does not discard an image metadata
  candidate; final parsing/codec validation happens when the page is opened.
- The Android bridge exposes a protocol version. Dart rejects an older native
  plugin with a clean-build instruction instead of treating stale output as an
  empty image directory.

## Consequences

Local-media I/O can evolve without growing the application page library. Tests
for filesystem enumeration and image sniffing live with `packages/local_media`.
A clean rebuild is required after changing the Android plugin; run
`./tool/clean.sh` before rebuilding when the protocol version changes.
