#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/demo_home_source_migration.dart').read_text()
session = (ROOT / 'apps/app/lib/home_library_session.dart').read_text()

restore = migration[
    migration.index('  Future<int> _restoreSourceVersionArtifactEquivalences('):
    migration.index('  Future<details.ComicDetailsVersionState> _loadSourceVersionState(')
]
assert 'final sourceChapterKeys = <String, ImportedLibraryChapterKey>{};' in restore
assert '_librarySession.hydrateChapterBatch(sourceChapterKeys.values)' in restore
assert '_librarySession.hydrateEntry(' not in restore
assert 'await _library.get(current.chapter.sourceId, sourceChapterId)' not in restore
assert 'hydratedSourceEntries[sourceIdentity]' in restore
assert '_exactChapterEntry(current.chapter.sourceId, sourceChapterId)' in restore

batch = session[
    session.index('  Future<Map<String, ImportedLibraryEntry>> hydrateChapterBatch('):
    session.index('  Future<List<ImportedLibraryEntry>> loadAuthoritativeEntries()')
]
assert 'library is ImportedLibraryBatchLookup' in batch
assert 'batch.getMany(keys.values)' in batch
assert "'chapter-hydrate-batch'" in batch

print('version reuse batch hydration: OK')
