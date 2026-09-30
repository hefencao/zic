#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / 'packages/downloads/lib/src/persistent_chapter_download_service.dart').read_text()
structured = (ROOT / 'packages/downloads/lib/src/persistent_download_structured_placement.dart').read_text()
store = (ROOT / 'packages/downloads/lib/src/persistent_download_artifact_store.dart').read_text()
sqlite = (ROOT / 'packages/storage/lib/src/sqlite_index.dart').read_text()
catalog = (ROOT / 'packages/catalog/lib/src/imported_chapter.dart').read_text()
manager = (ROOT / 'apps/app/lib/download_manager.dart').read_text()
commands = (ROOT / 'apps/app/lib/home_download_commands.dart').read_text()
app_sources = ''.join(
    path.read_text()
    for path in (ROOT / 'apps/app/lib').glob('*.dart')
)

errors = []

def require(source, needle, message):
    if needle not in source:
        errors.append(message)

def forbid(source, needle, message):
    if needle in source:
        errors.append(message)

require(structured, 'Future<Map<int, ({String path, int bytes})>> scanExistingPages(',
        'structured artifact owner must own the explicit directory scan')
if service.count('scanExistingPages(') != 1:
    errors.append('chapter service must have exactly one production directory-scan call')
audit_start = service.find('Future<ChapterFileAuditReport> _runChapterFileAudit(')
audit_end = service.find('Future<void> cancelChapterFileAudit(', audit_start)
scan = service.find('scanExistingPages(')
if not (0 <= audit_start < scan < audit_end):
    errors.append('directory scan must remain inside explicit chapter-file audit')
forbid(app_sources, 'scanExistingPages(', 'UI/composition must not enumerate download directories')
require(service, 'final token = CancelToken();',
        'chapter-file audit cancellation must be service-generation owned')
require(service, 'await artifactStore.adoptExistingPageRecord(',
        'repair must reuse the existing artifact adoption authority')
require(service, 'final expectedChecksum = _sourceCrc32Constraint(page);',
        'unindexed repair must require source-declared CRC32 proof')
require(service, 'unprovenPages++;',
        'files without comparable source proof must remain audit-only')
require(catalog, 'final String? checksumAlgorithm;',
        'persisted imported pages must preserve the source checksum namespace')
require(catalog, 'checksum: page.checksum,',
        'remote PageAsset checksum must survive ImportedPageRecord projection')
require(store, 'await _index.removeArtifactAuthorityIfNoReplicas(artifactId);',
        'last-replica structural retirement must converge binding authority immediately')
require(sqlite, 'Future<bool> removeArtifactAuthorityIfNoReplicas(String artifactId)',
        'SQLite must own the zero-replica conditional binding transaction')
require(manager, "tooltip: '校验/修复离线文件'",
        'Download Manager must expose the explicit repair/audit command')
require(commands, '_activeFileAudits',
        'Home command owner must retain the starting service generation for cancellation')

if errors:
    for error in errors:
        print(f'FAIL: {error}')
    raise SystemExit(1)
print('download repair/audit ownership: OK')
