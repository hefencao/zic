# ADR 0009: unified source-aware comic details

- Status: Superseded by ADR 0010
- Version: `0.22.0-dev.26`

## Context

The source browser and persisted Home/History/Bookshelf routes presented different details for the
same remote comic. A source owns a complete and mutable upstream chapter catalog, while the library
contains only chapters the user has opened or saved. Treating either list as the other loses content
or silently imports data.

## Decision

All entry routes use `UnifiedComicDetailsScreen`. It receives source bindings and an immutable library
snapshot, then projects chapters by `sourceId + chapterId`. Source manifests win for current metadata;
persisted entries contribute progress, read state and durable page manifests. Persisted entries absent
from a loaded source manifest remain visible as local-retained chapters. Upstream-only entries remain
non-durable until the user opens or explicitly adds them.

Pull-to-refresh invokes source and library callbacks; the Widget never reads files, performs raw HTTP,
or owns Reader artifacts. Remote author, description and cover metadata is stored in backward-compatible
chapter JSON so a library route can render the same header before source refresh completes.

## Supersession

Version 0.23.0-dev.27 retained the shared presentation pieces but restored separate remote and local state owners. See ADR 0010.

## Consequences

- Details behavior and visuals remain consistent across all routes.
- Refresh can show new chapters without changing shelf contents.
- Multi-source chapter rows and transient state cannot collide on chapter ID alone.
- Durable remote-update ingestion and cross-source canonical-work matching remain separate future work.
