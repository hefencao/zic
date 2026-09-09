#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/demo_home_source_migration.dart').read_text()
reader = (ROOT / 'apps/app/lib/demo_home_reader_route.dart').read_text()
compat = (ROOT / 'apps/app/lib/demo_home_source_compat.dart').read_text()

# Merely rendering details must not prove page equivalence. Version discovery,
# explicit version viewing and Reader entry are the three preparation owners.
assert '_scheduleVersionReuseWarmup(' not in compat

# Reader consumes a pending detail->Reader preparation before physical demand,
# can synchronously fill a missing focused mapping, then refreshes metadata and
# version relations asynchronously after the Reader is allowed to start.
for token in (
    'final viewReusePreparation = _versionViewReusePreparationFor(current);',
    'await viewReusePreparation;',
    'await _prepareVersionReuseWarmup(versionSource, current);',
    '_scheduleReaderMetadataVersionRefresh(versionSource, current);',
):
    assert token in reader, token
assert '_scheduleVersionReuseWarmup(versionSource, current);' not in reader

# Warmup remains chapter-generation scoped and never owns version discovery.
prepare_start = migration.index('  Future<void> _prepareVersionReuseWarmup(')
prepare_end = migration.index('  void _scheduleVersionReuseWarmup(', prepare_start)
prepare = migration[prepare_start:prepare_end]
assert 'ImportedLibraryEntry focus' in prepare
assert '_versionReuseWarmupKey(source, focus)' in prepare
assert '_warmVersionRelationPageMappings(source, relation, focus)' in prepare
assert 'refreshAvailability: true' in prepare
assert 'findComicVersions' not in prepare

# Focused proof loads at most the related comic/chapter and is only attempted
# when either side has actual READY/partial/hot reusable physical state.
warm_start = migration.index('  Future<void> _warmVersionRelationPageMappings(')
warm_end = migration.index('  String _versionReuseWarmupKey(', warm_start)
warm = migration[warm_start:warm_end]
assert warm.count('source.loadComic(') == 1
assert 'candidate.sequence == focus.chapter.sequence' in warm
assert 'final focusManifest = focus.chapter.toManifest();' in warm
assert '_chapterHasReusableVersionSourceState(predecessorManifest)' in warm
assert '_chapterHasReusableVersionSourceState(successorManifest)' in warm

# Version-state refresh is allowed to warm cached-page matching just like
# VibeVenera details, while explicit "view version" carries the same Future to
# a quickly-entered Reader instead of racing it.
version_state_start = migration.index('  Future<details.ComicDetailsVersionState> _loadSourceVersionState(')
version_state_end = migration.index('  bool _sourceComicHasUpdate(', version_state_start)
version_state = migration[version_state_start:version_state_end]
assert 'findComicVersions' in version_state
assert '_scheduleVersionReuseWarmup(' in version_state

view_start = migration.index('  Future<void> _viewSourceVersion(')
view_end = migration.index('  Future<void> _migrateSourceVersion(', view_start)
view = migration[view_start:view_end]
assert '_startVersionViewReusePreparation(' in view
assert '_versionViewReusePreparations' in migration

# Existing-state lookup is bounded to candidate keys, but zic streaming partials
# and joinable hot physical sessions are first-class reusable state.
assert 'findExistingReusableKeys(' in migration
assert 'existing.partialKeys' in migration
assert 'hasReusableEquivalentPhysicalState(candidate.source)' in migration

print('version reuse warmup scope: OK')
