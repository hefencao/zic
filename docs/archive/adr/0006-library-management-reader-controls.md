# ADR 0006: Library management gestures and Reader control ownership

## Status

Accepted for `0.20.0-dev.23`.

## Context

Bookshelf custom sorting changed its visual form, management taps still opened content, category
views could not add or move comics, and destructive actions were adjacent to ordinary actions. The
Reader exposed app controls by default, had no bottom command surface, and lacked zoom gesture
arbitration. A direct replacement of the WebP widget to add pause/speed would have bypassed existing
download identity, telemetry and native fallback ownership.

## Decision

- Sort mode and view mode are independent. Gallery is the default for every sort, while users may
  explicitly choose list view.
- Management mode changes card tap from navigation to selection. Custom gallery order uses
  `LongPressDraggable` plus identity-based `DragTarget`; custom list order uses
  `ReorderableListView`. Reorder commands persist through the library store.
- Category insertion and move are application commands over `ComicPreference`. Delete is visually
  isolated, colored as destructive and confirmed before removing catalog records.
- Home and Bookshelf use one `ComicCoverCard` geometry contract. The Home directory-maintenance
  panel is removed; diagnostics are collapsed and secondary.
- Reader enters immersive mode with app overlays hidden. Overlay controls submit commands to
  `ReaderController`, application callbacks or the existing download registry.
- Page zoom is presentation-local. While scale exceeds identity, PageView physics are disabled.
  Navigation recreates the old/current zoom host so transforms do not survive page changes.
- Pause/speed state is injected through `ReaderPageRuntime` into the existing GIF/WebP player. It
  must retain download identity, viewport raster selection, telemetry and Flutter/native fallback.

## Consequences

The UI has explicit browse/manage semantics and fewer accidental destructive paths. Gesture
ownership is testable by stable keys and persisted identities. Reader controls do not become media
resource owners. The built-in chapter-cache command is still tied to the session workspace; durable
offline download state and cover waterlines require a later storage projection.
