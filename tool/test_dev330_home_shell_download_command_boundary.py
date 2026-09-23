#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f'HomeShell download-command boundary missing {label}: {marker}')


home = text('apps/app/lib/home_shell.dart')
compat = text('apps/app/lib/home_shell_source_compat.dart')
ui = '\n'.join(
    path.read_text(encoding='utf-8')
    for path in sorted((ROOT / 'apps/app/lib').glob('home_shell*.dart'))
)
commands = text('apps/app/lib/home_download_commands.dart')

for marker, label in (
    ('final class HomeDownloadCommands', 'download command owner'),
    ('final HomeLibrarySession session;', 'session generation authority'),
    ('session.chapterDownloads', 'chapter service delegation'),
    ('session.wholeComicDownloads', 'whole-comic service delegation'),
    ('Future<ChapterDownloadSnapshot> downloadChapter(', 'chapter sequencing'),
    ('Future<ChapterDownloadSnapshot> retryChapter(', 'retry sequencing'),
    ('Future<void> pauseWholeComicJob(', 'queue pause sequencing'),
    ('Future<void> updateWholeComicPolicy(', 'queue policy sequencing'),
    ('Future<ChapterDownloadSnapshot> deleteChapterFiles(', 'archive file-delete sequencing'),
    ('await ensureDurableServices();\n    final hydrated = await session.hydrateEntry(entry);\n    await session.chapterDownloads.delete(hydrated);', 'durable file-delete boundary'),
    ('Future<HomeWholeComicDownloadStart> downloadComicEntries(', 'whole-comic sequencing'),
    ('final refreshed = await refreshStaleChapter(current);', 'stale authority refresh'),
):
    require(commands, marker, label)

for forbidden in ('BuildContext', 'Navigator', 'setState(', '_HomeShellState'):
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
    ('onDeleteChapter: _downloadCommands.deleteChapter,', 'details delete adapter'),
    ('_downloadCommands.deleteChapterFiles(entry);', 'archive file-delete adapter'),
    ('probeExisting: _downloadCommands.probeExisting,', 'details probe adapter'),
    ('await _downloadCommands.stopChapter(entry);', 'details stop adapter'),
    ('toggleWholeComicPause: _downloadCommands.toggleWholeComicPause,', 'details pause adapter'),
    ('claimComicDirectory: _downloadCommands.claimComicDirectory,', 'details placement adapter'),
    ('getDownloadPlacement: _downloadCommands.getDownloadPlacement,', 'details placement read adapter'),
    ('inspectChapter: _downloadCommands.inspectChapter,', 'details inspect adapter'),
    ('final snapshot = await _downloadCommands.downloadChapter(entry);', 'chapter UI wrapper'),
    ('final started = await _downloadCommands.downloadComicEntries(', 'whole-comic UI wrapper'),
    ('commandActions: DownloadManagerCommandActions(', 'download-manager command adapter'),
    ('retryChapter: _downloadCommands.retryChapter,', 'manager retry adapter'),
    ('deleteChapterFiles: _downloadCommands.deleteChapterFiles,', 'manager delete adapter'),
    ('pauseWholeComicJob: _downloadCommands.pauseWholeComicJob,', 'manager queue adapter'),
    ('updateWholeComicPolicy: _downloadCommands.updateWholeComicPolicy,', 'manager policy adapter'),
):
    require(ui, marker, label)

for redundant in (
    '_inspectChapterDownload(',
    '_inspectChapterDownloads(',
    '_inspectComicConflictsForDetails(',
    '_stopChapterDownload(',
    '_toggleWholeComicPause(',
    '_deleteChapter(',
):
    if redundant in compat:
        raise SystemExit(
            f'HomeShell retained redundant download command pass-through: {redundant}'
        )

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
            f'HomeShell UI re-acquired download command authority: {forbidden}'
        )

settings = text('apps/app/lib/app_settings_screen.dart')
for marker, label in (
    ('final class WholeComicPolicySettingsBinding', 'settings policy capability bundle'),
    ('final Listenable changes;', 'settings projection invalidation'),
    ('final WholeComicQueueSnapshot Function() readSnapshot;', 'settings projection reader'),
    ('final Future<void> Function(WholeComicQueuePolicy policy) updatePolicy;', 'settings policy command'),
    ('NetworkSettingsScreen(\n                policyBinding: downloadPolicy,', 'network settings binding'),
    ('DownloadSettingsScreen(policyBinding: downloadPolicy)', 'download settings binding'),
):
    require(settings, marker, label)
for forbidden in (
    'final WholeComicDownloadQueue downloads;',
    'widget.downloads.updatePolicy(',
    'downloads.updatePolicy(',
):
    if forbidden in settings:
        raise SystemExit(
            f'Settings re-acquired concrete whole-comic queue authority: {forbidden}'
        )

for marker, label in (
    ('downloadPolicy: WholeComicPolicySettingsBinding(', 'settings generation binding'),
    ('changes: _librarySession.downloadProjectionChanges,', 'settings projection changes'),
    ('readSnapshot: () => _librarySession.wholeComicQueueSnapshot,', 'settings current snapshot'),
    ('updatePolicy: _downloadCommands.updateWholeComicPolicy,', 'settings policy command owner'),
):
    require(home, marker, label)

manager = text('apps/app/lib/download_manager.dart')
for marker, label in (
    ('final class DownloadManagerCommandActions', 'manager mutation capability bundle'),
    ('final DownloadManagerCommandActions? commandActions;', 'manager command capability input'),
    ('final actions = widget.commandActions;', 'manager command dispatch'),
    ('await actions.downloadChapter(entry)', 'manager download owner dispatch'),
    ('await actions.retryChapter(entry)', 'manager retry owner dispatch'),
    ('await actions.stopChapter(entry)', 'manager stop owner dispatch'),
    ('await actions.deleteChapterFiles(entry)', 'manager delete owner dispatch'),
):
    require(manager, marker, label)

print('dev.330 HomeShell download command boundary: OK')
