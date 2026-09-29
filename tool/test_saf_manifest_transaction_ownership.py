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


store = read('packages/downloads/lib/src/persistent_download_artifact_store.dart')
placement = read(
    'packages/downloads/lib/src/persistent_download_structured_placement.dart'
)
check = read('tool/check.sh')

for token in (
    "File('$resolvedIndexPath.owner.lock')",
    'metadataOwnerLock.lock(FileLock.exclusive)',
    '_processMetadataOwners.add(resolvedIndexPath)',
    '_processMetadataOwners.remove(_metadataOwnerKey)',
    'await resolved._recoverStructuredSafManifestTransactions()',
):
    require(store, token, 'persistent metadata process ownership')
if store.index('metadataOwnerLock.lock(FileLock.exclusive)') > store.index(
    'await index.open()'
):
    raise SystemExit('ERROR: metadata owner lock must precede SQLite open/recovery')

for token in (
    "'$manifestPath.zic-old'",
    "Directory('$_metadataOwnerKey.saf-manifest-transactions')",
    '_SafManifestTransactionIntent',
    '_writeSafManifestTransactionIntent(',
    '_recoverSafManifestIntent(',
    '_recoverSafManifestCommit(',
    '_commitSafManifestAndPlacement(',
    '_commitSafManifestDeletion(',
    '_persistPlacementExact(',
):
    require(placement, token, 'SAF manifest/placement transaction')
forbid(
    placement,
    'target.generation > placement.generation',
    'SAF manifest generation-ahead recovery heuristic',
)

write_start = placement.index('Future<void> writeComicFolderManifest(')
write_end = placement.index('Future<void> cleanupStructuredChapterExport(', write_start)
write_body = placement[write_start:write_end]
require(write_body, '_commitSafManifestAndPlacement(', 'SAF manifest writer')
forbid(write_body, '_writeBytesToSafTracked(', 'SAF manifest writer bypass')

replace_start = placement.index('Future<void> _commitSafManifestAndPlacement(')
replace_end = placement.index('Future<void> _commitSafManifestDeletion(', replace_start)
replace_body = placement[replace_start:replace_end]
if replace_body.index('_writeSafManifestTransactionIntent(') > replace_body.index(
    'io.rename(manifestPath, backupPath)'
):
    raise SystemExit('ERROR: SAF manifest replace intent must precede target mutation')
if replace_body.index('_writeSafManifestTransactionIntent(') > replace_body.index(
    '_persistPlacementExact(placement)'
):
    raise SystemExit('ERROR: SAF manifest replace intent must precede placement commit')

delete_start = placement.index('Future<void> _commitSafManifestDeletion(')
delete_end = placement.index('Future<ComicFolderManifest?> _readComicFolderManifest(', delete_start)
delete_body = placement[delete_start:delete_end]
if delete_body.index('_writeSafManifestTransactionIntent(') > delete_body.index(
    'io.rename(manifestPath, backupPath)'
):
    raise SystemExit('ERROR: SAF manifest delete intent must precede target mutation')
if delete_body.index('io.rename(manifestPath, backupPath)') > delete_body.index(
    '_index.removePlacement('
):
    raise SystemExit('ERROR: SAF manifest delete backup must precede placement commit')

remove_start = placement.index('Future<void> removeChapterFromComicFolderManifest(')
remove_end = placement.index('void _rejectLocalPathLinks(', remove_start)
remove_body = placement[remove_start:remove_end]
require(remove_body, '_commitSafManifestAndPlacement(', 'SAF manifest removal rewrite')
require(remove_body, '_commitSafManifestDeletion(', 'SAF manifest final deletion')
forbid(remove_body, "safIo.delete('$comicDir/$comicManifestFileName')", 'SAF manifest deletion bypass')
forbid(remove_body, '_writeBytesToSafTracked(', 'SAF manifest removal bypass')

require(
    check,
    'test_saf_manifest_transaction_ownership.py',
    'repository SAF manifest ownership gate',
)
print('SAF manifest/placement transaction ownership: OK')
