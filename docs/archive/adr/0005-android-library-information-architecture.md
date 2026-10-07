# ADR 0005: Android library information architecture

## Status

Accepted for the current v0.x iteration.

## Context

The original demo home mixed media diagnostics, local-folder maintenance and the
user-facing library into one long list. Android now needs a product navigation
model that can grow to remote sources without bypassing the existing catalog,
storage and Reader ownership rules.

## Decision

The application uses two primary destinations:

1. Home: recently updated comics, reading history, import actions and retained
   media diagnostics.
2. Bookshelf: source/category filters, management, sorting and custom ordering.

`ImportedLibraryStore` remains the single application-facing persistence
contract and now also owns:

- custom categories;
- per-comic shelf/liked/collected/category/custom-order preferences;
- explicit chapter read/unread state.

The durable implementation stores those records beside imported chapters and
reading progress in SQLite schema version 2. App widgets do not own filesystem
or SQLite access.

A cover card receives a byte loader and optional page download progress. It may
render animated WebP/GIF through `Image.memory`, but it does not create download
or decode sessions. Local comics without rich metadata open Reader on tap and
long press; sources with metadata may use the same card contract to open a
comic-details route on long press.

## Consequences

- Local and future remote comics share one shelf preference model.
- Custom order is durable and reorder operations preserve comics hidden by the
  active filter.
- Chapter read state is separate from precise Reader progress, allowing a
  right-swipe action to restore unread without destroying the last page.
- Download waterline UI is reusable, while authoritative progress remains a
  session/catalog concern to be connected by remote-source work.
