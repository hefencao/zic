#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f'dev.336 Home shelf-management boundary missing {label}: {marker}'
        )


owner = text('apps/app/lib/home_shelf_management.dart')
home = '\n'.join(
    text(path)
    for path in (
        'apps/app/lib/home_shell.dart',
        'apps/app/lib/home_shell_views.dart',
    )
)

for marker, label in (
    ('final class HomeShelfManagement', 'standalone presentation-state owner'),
    ('bool get managing => _managing;', 'management mode projection'),
    ('bool get batchSelecting => _batchSelecting;', 'batch mode projection'),
    ('bool isSelected(String identity)', 'identity-local selection lookup'),
    ('void toggleManaging()', 'management mode transition'),
    ('void clearSelection()', 'selection reset'),
    ('void startBatchSelection(String identity)', 'batch admission'),
    ('void toggleBatchSelection(String identity)', 'batch selection transition'),
    ('void removeSelection(String identity)', 'deleted-item selection cleanup'),
):
    require(owner, marker, label)

for forbidden in (
    "package:flutter/",
    'BuildContext',
    'Navigator',
    'State<',
    'StatefulWidget',
    'setState(',
    'LibraryComic',
    'HomeLibrarySession',
    'HomeDownloadCommands',
    'HomeVersionReuseLifecycle',
    'BrowsableComicSource',
    'ChapterDownload',
    'ResourceCacheCoordinator',
):
    if forbidden in owner:
        raise SystemExit(
            f'HomeShelfManagement leaked UI/subsystem authority: {forbidden}'
        )

for marker, label in (
    ('final HomeShelfManagement _shelfManagement = HomeShelfManagement();', 'Home binding'),
    ('_shelfManagement.toggleManaging', 'management transition delegation'),
    ('_shelfManagement.startBatchSelection(comic.identity)', 'batch start delegation'),
    ('_shelfManagement.toggleBatchSelection(comic.identity)', 'selection toggle delegation'),
    ('_shelfManagement.removeSelection(comic.identity)', 'selection cleanup delegation'),
    ('_shelfManagement.clearSelection()', 'selection reset delegation'),
    ('_shelfManagement.isSelected(comic.identity)', 'selection projection'),
):
    require(home, marker, label)

for stale in (
    'bool _manageShelf',
    'bool _batchManagement',
    '_managedComicIdentities',
):
    if stale in home:
        raise SystemExit(
            f'HomeShell retained parallel shelf-management state: {stale}'
        )

print('dev.336 HomeShell shelf management boundary: OK')
