#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/demo_home_source_migration.dart').read_text()
session = (ROOT / 'apps/app/lib/home_library_session.dart').read_text()

authority = migration[
    migration.index('  Future<int> _ensureSourceVersionReuseAuthority('):
    migration.index('  Future<details.ComicDetailsVersionState> _loadSourceVersionState(')
]
# Reader authority catch-up consumes already-materialized canonical endpoints.
# It must not revive the old whole-history chapter hydration/enumeration path.
for required in (
    'await _librarySession.ensureCanonicalMediaForEntry(current);',
    '_librarySession.versionRelations',
    '_librarySession.versionAuthorityEntry(',
    "'restoreMode': 'canonical-media-direct'",
    'mapping.effectiveVerifiedIntervals',
):
    assert required in authority, required
for forbidden in (
    'hydrateChapterBatch(',
    '_librarySession.hydrateEntry(',
    'await _library.get(',
    '_sourceVersionRelationsForComic(',
    'sourceChapterKeys',
):
    assert forbidden not in authority, forbidden

# Batch hydration remains a library-owned targeted capability for callers that
# genuinely need a known chapter set; removing it from Reader authority must
# not degrade that primitive into per-chapter storage lookup.
batch = session[
    session.index('  Future<Map<String, ImportedLibraryEntry>> hydrateChapterBatch('):
    session.index('  Future<List<ImportedLibraryEntry>> loadAuthoritativeEntries()')
]
assert 'library is ImportedLibraryBatchLookup' in batch
assert 'batch.getMany(keys.values)' in batch
assert "'chapter-hydrate-batch'" in batch
assert '_rememberVersionAuthorityEntries(entries);' in batch

print('version reuse direct canonical authority: OK')
