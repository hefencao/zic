#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, message: str) -> None:
    if marker not in body:
        raise SystemExit(f'{message}: {marker}')


service = read('packages/downloads/lib/src/chapter_downloads.dart')
placement = read('packages/downloads/lib/src/persistent_download_structured_placement.dart')
inspector = read('packages/downloads/lib/src/comic_conflict_inspector.dart')
details = read('apps/app/lib/comic_details.dart')
dialog = read('apps/app/lib/comic_download_conflict_dialog.dart')
commands = read('apps/app/lib/home_download_commands.dart')
queue = read('packages/downloads/lib/src/whole_comic_downloads.dart')

for marker in (
    'Set<String>? requiredDirectoryNames,',
    'Future<ComicConflictReport> inspectComicConflicts({',
):
    require(service, marker, 'chapter conflict capability lost required target projection')

for marker in (
    'final requiredDirectories = <String>{',
    'for (final placement in await _index.listPlacements())',
    'requiredDirectoryNames:',
    'knownOwners[directory] = (',
):
    require(placement, marker, 'placement owner no longer projects explicit conflict targets')

for marker in (
    'this.observedOwnerKey,',
    'String? get effectiveObservedOwnerKey',
    'Set<String> get occupiedDirectoryNames',
    'requiredDirectoryNames?.contains(folderName)',
    'observedOwnerKey != null',
):
    require(inspector, marker, 'conflict inspector lost durable owner or occupied-directory semantics')

for marker in (
    'final existingPlacement = await downloadActions.getDownloadPlacement(',
    'requiredDirectoryNames: forcePrompt &&',
    'additionalOccupiedDirectoryNames: report.occupiedDirectoryNames',
    'chosenCandidate?.effectiveObservedOwnerKey',
):
    require(details, marker, 'details conflict resolution reacquired guess-based ownership')

for marker in (
    'final occupied = report.occupiedDirectoryNames;',
    'while (occupied.contains(candidate));',
):
    require(dialog, marker, 'save-as-new naming no longer respects all occupied candidates')

for marker in (
    'if (job.sourceId == sourceId && job.comicId == comicId)',
    'requiredDirectoryNames: requiredDirectoryNames',
):
    require(commands, marker, 'Home download command identity/required-target boundary regressed')

for marker in (
    'final identity = comicLibraryIdentity(sourceId, comicId);',
    'if (job.comicIdentity == identity)',
):
    require(queue, marker, 'whole-comic queue lookup is no longer source-scoped')

print('download conflict resolution ownership: OK')
