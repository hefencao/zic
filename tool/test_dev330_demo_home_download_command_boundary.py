#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f'DemoHome download-command boundary missing {label}: {marker}')


home = text('apps/app/lib/demo_home.dart')
compat = text('apps/app/lib/demo_home_source_compat.dart')
ui = '\n'.join(
    path.read_text(encoding='utf-8')
    for path in sorted((ROOT / 'apps/app/lib').glob('demo_home*.dart'))
)
commands = text('apps/app/lib/home_download_commands.dart')

for marker, label in (
    ('final class HomeDownloadCommands', 'download command owner'),
    ('final HomeLibrarySession session;', 'session generation authority'),
    ('session.chapterDownloads', 'chapter service delegation'),
    ('session.wholeComicDownloads', 'whole-comic service delegation'),
    ('Future<ChapterDownloadSnapshot> downloadChapter(', 'chapter sequencing'),
    ('Future<void> deleteChapterFiles(', 'archive file-delete sequencing'),
    ('await ensureDurableServices();\n    final hydrated = await session.hydrateEntry(entry);\n    await session.chapterDownloads.delete(hydrated);', 'durable file-delete boundary'),
    ('Future<HomeWholeComicDownloadStart> downloadComicEntries(', 'whole-comic sequencing'),
    ('final refreshed = await refreshStaleChapter(current);', 'stale authority refresh'),
):
    require(commands, marker, label)

for forbidden in ('BuildContext', 'Navigator', 'setState(', '_DemoHomeState'):
    if forbidden in commands:
        raise SystemExit(
            f'HomeDownloadCommands acquired UI state/navigation authority: {forbidden}'
        )

for marker, label in (
    ('late final HomeDownloadCommands _downloadCommands;', 'state command collaborator'),
    ('_downloadCommands = HomeDownloadCommands(', 'command composition wiring'),
    ('session: _librarySession,', 'session injection'),
):
    require(home, marker, label)

for marker, label in (
    ('_downloadCommands.deleteChapter(entry, deleteFiles: deleteFiles);', 'shelf removal adapter'),
    ('_downloadCommands.deleteChapterFiles(entry);', 'archive file-delete adapter'),
    ('probeExisting: _downloadCommands.probeExisting,', 'details probe adapter'),
    ('claimComicDirectory: _downloadCommands.claimComicDirectory,', 'details placement adapter'),
    ('getDownloadPlacement: _downloadCommands.getDownloadPlacement,', 'details placement read adapter'),
    ('inspectChapter: _downloadCommands.inspectChapter,', 'details inspect adapter'),
    ('final snapshot = await _downloadCommands.downloadChapter(entry);', 'chapter UI wrapper'),
    ('final started = await _downloadCommands.downloadComicEntries(', 'whole-comic UI wrapper'),
):
    require(ui, marker, label)

for forbidden in (
    '_chapterDownloads.download(',
    '_chapterDownloads.retry(',
    '_chapterDownloads.cancel(',
    '_chapterDownloads.delete(',
    '_chapterDownloads.probeExistingDownloads(',
    '_chapterDownloads.inspectComicConflicts(',
    '_chapterDownloads.claimComicDirectory(',
    '_chapterDownloads.getDownloadPlacement(',
    '_wholeComicDownloads.enqueue(',
    '_wholeComicDownloads.pause(',
    '_wholeComicDownloads.resume(',
):
    if forbidden in ui:
        raise SystemExit(
            f'DemoHome UI re-acquired download command authority: {forbidden}'
        )

print('dev.330 DemoHome download command boundary: OK')
