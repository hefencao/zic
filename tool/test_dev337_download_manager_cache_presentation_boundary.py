#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f'dev.337 Download Manager cache presentation boundary missing {label}: {marker}'
        )


model = text('packages/downloads/lib/src/chapter_downloads.dart')
service = text('packages/downloads/lib/src/persistent_chapter_download_service.dart')
ui = text('apps/app/lib/download_manager.dart')

for marker, label in (
    ('this.historicalRevision = false', 'historical exact-revision qualification'),
    ('final bool historicalRevision;', 'historical exact-revision field'),
    ('ImportedChapterRecord? displayMetadata', 'presentation metadata alias input'),
    ("? '未关联漫画'", 'safe orphan comic fallback'),
    ("? '未关联章节缓存'", 'safe orphan chapter fallback'),
):
    require(model, marker, label)

for marker, label in (
    ('displayMetadataByLogicalChapter', 'current logical chapter metadata index'),
    ('_logicalChapterManagementKey(', 'revision-independent presentation key'),
    ('displayMetadata: displayMetadata', 'exact cache display alias projection'),
):
    require(service, marker, label)

for marker, label in (
    ("label: '自动缓存'", 'user-facing cache tab label'),
    ("title: '版本共享缓存'", 'version-sharing cache section'),
    ("title: '章节页面缓存'", 'exact cache section'),
    ("'旧版本页面缓存'", 'historical exact cache label'),
    ('!cache.historicalRevision', 'historical revision conversion guard'),
    ('_isLibraryEntry(snapshot)', 'current library target conversion guard'),
):
    require(ui, marker, label)

exact_start = ui.index('final class _ExactCacheTaskTile')
exact_end = ui.index('final class _AutoCacheTaskTile', exact_start)
exact_tile = ui[exact_start:exact_end]
auto_start = exact_end
auto_end = ui.index('String _identity(', auto_start)
auto_tile = ui[auto_start:auto_end]
canonical_start = ui.index('final class _CanonicalCacheTaskTile')
canonical_end = exact_start
canonical_tile = ui[canonical_start:canonical_end]

for body, label in (
    (exact_tile, 'Exact cache tile'),
    (auto_tile, 'compatibility auto-cache tile'),
    (canonical_tile, 'Canonical cache tile'),
):
    for forbidden in ('${cache.sourceId}', '${snapshot.sourceId}', 'Exact 缓存'):
        if forbidden in body:
            raise SystemExit(
                f'{label} leaked internal cache/source presentation field: {forbidden}'
            )

for forbidden in ('mihon:', 'ExternalPluginController', 'plugin_host_bridge'):
    if forbidden in exact_tile or forbidden in canonical_tile:
        raise SystemExit(
            f'Download Manager cache tile added plugin-specific presentation logic: {forbidden}'
        )

print('dev.337 Download Manager cache presentation boundary: OK')
