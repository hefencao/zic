#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(source: str, token: str, label: str) -> None:
    if token not in source:
        raise SystemExit(f'ERROR: {label}: missing {token!r}')


def forbid(source: str, token: str, label: str) -> None:
    if token in source:
        raise SystemExit(f'ERROR: {label}: found {token!r}')


app = read('apps/app/lib/app_runtime.dart')
settings = read('apps/app/lib/app_settings_screen.dart')
directory = read('apps/app/lib/chapter_download_directory.dart')
preferences = read('apps/app/lib/app_preferences.dart')
downloads = read('packages/downloads/lib/src/chapter_downloads.dart')
placement = read(
    'packages/downloads/lib/src/persistent_download_structured_placement.dart'
)
legacy = read('packages/storage_bridge/lib/storage_bridge.dart')
check = read('tool/check.sh')

for token in (
    'migrateStructuredDirectRootAndClose(',
    'migratePersistentDownloadStructuredDirectRoot(',
    'chapterDownloadDirectoryMigrationSupported(current, target)',
    'chapterDownloadReplicaMigrationProtocolV1',
    'pendingSourceBefore ?? configuredCurrent',
    'privateReplicaMigration',
    'unknownPendingProtocol',
):
    require(app, token, 'App direct-root migration ownership')
forbid(app, 'moveChapterDownloadStore(', 'App legacy whole-tree migration')

for token in (
    'chapterDownloadDirectoryMigrationSupported(',
    'crossesSafBoundary',
    'value: crossesSafBoundary ? false : migrate',
):
    require(settings, token, 'Settings migration policy projection')
for token in (
    "chapterDownloadSafTreeUri(source) == null",
    "chapterDownloadSafTreeUri(destination) == null",
    "chapterDownloadReplicaMigrationProtocolV1",
):
    require(directory, token, 'Direct-root migration policy')
for token in (
    'chapterDownloadDirectoryPendingMoveProtocol',
    'setChapterDownloadDirectoryPendingMoveProtocol',
):
    require(preferences, token, 'Durable migration protocol marker')

for token in (
    'migrateStructuredDirectRootAndClose({',
    'migratePersistentDownloadStructuredDirectRoot({',
):
    require(downloads, token, 'Persistent composition migration lifecycle')
for token in (
    'migrateArtifactReplica(',
    'record.pinned',
    'CacheState.ready',
    'generation: placement.generation + 1',
    'destination contains different bytes',
):
    require(placement, token, 'Replica-scoped root migration')
for token in (
    'storePhysicalPartialDownload',
    'PhysicalPartialRecord',
):
    forbid(placement, token, 'Root migration partial-spool ownership')

# Legacy whole-tree recovery remains available only in storage_bridge for
# pre-App-private metadata adoption; current AppRuntime must never invoke it.
require(legacy, 'moveChapterDownloadStore(', 'Legacy metadata recovery')
require(
    check,
    'test_download_root_migration_ownership.py',
    'Repository root migration ownership gate',
)

print('download root replica-migration ownership: OK')
