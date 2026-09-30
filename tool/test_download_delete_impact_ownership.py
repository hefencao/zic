#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, message: str) -> None:
    if marker not in body:
        raise SystemExit(message + ': ' + marker)


def forbid(body: str, marker: str, message: str) -> None:
    if marker in body:
        raise SystemExit(message + ': ' + marker)


model = read('packages/downloads/lib/src/chapter_downloads.dart')
service = read('packages/downloads/lib/src/persistent_chapter_download_service.dart')
store = read('packages/downloads/lib/src/persistent_download_artifact_store.dart')
ui = read('apps/app/lib/download_manager.dart')
commands = read('apps/app/lib/home_download_commands.dart')
wiring = read('apps/app/lib/home_shell_source_compat.dart')

for marker in (
    'final class ChapterDeleteImpactProjection',
    'abstract interface class ChapterDeleteImpactProjectionReader',
    'Actual deletion must still execute through',
):
    require(model, marker, 'delete-impact projection contract missing')

for marker in (
    'final manifest = entry.chapter.toManifest();',
    'for (final page in manifest.pages) _downloadId(manifest, page)',
    'artifactStore.inspectChapterDeleteImpact(',
):
    require(service, marker, 'persistent service must project the exact mutation target set')

for marker in (
    'final requestedKeys = <String>{for (final id in targetIds) id.key};',
    'final outside = records',
    'final canonical = await _index.listPhysicalMediaArtifacts();',
    'group.artifactIds.contains(record.effectiveArtifactId)',
    'group.artifactIds.contains(record.artifactId)',
):
    require(store, marker, 'artifact owner must derive delete impact from durable references')

for marker in (
    'inspectDeleteImpact: _downloadCommands.inspectDeleteImpact',
):
    require(wiring, marker, 'production composition must expose the read-only delete-impact action')

for marker in (
    'await ensureDurableServices();',
    'final hydrated = await session.hydrateEntry(entry);',
    'ChapterDeleteImpactProjectionReader',
):
    require(commands, marker, 'delete-impact read must use current durable service generation')

for marker in (
    'widget.commandActions?.inspectDeleteImpact',
    '_deleteImpactMessage(snapshot, impact)',
    '_DownloadManagerChapterCommand.deleteFiles',
    '实际删除会再次按最新引用关系校验',
):
    require(ui, marker, 'Download Manager delete-impact presentation boundary missing')

for forbidden in (
    'isPathOrArtifactReferenced(',
    'listPhysicalMediaArtifacts(',
    'CacheRec(',
    'artifactStore._index',
    'File(',
    'Directory(',
):
    forbid(ui, forbidden, 'Download Manager acquired durable reference/filesystem ownership')

print('download revision delete-impact ownership: OK')
