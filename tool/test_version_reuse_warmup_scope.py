#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/demo_home_source_migration.dart').read_text()
reader = (ROOT / 'apps/app/lib/demo_home_reader_route.dart').read_text()
compat = (ROOT / 'apps/app/lib/demo_home_source_compat.dart').read_text()

# Merely rendering details must not prove page equivalence. Version discovery,
# explicit version viewing and Reader entry are the three preparation owners.
assert '_scheduleVersionReuseWarmup(' not in compat

# Reader may block before physical demand only for an explicitly selected
# version-view Future. Generic history proof stays asynchronous and starts only
# after the first actual presentation frame; ordinary Reader entry consumes only
# the already-published compact version authority.
for token in (
    'final viewReusePreparation = _versionViewReusePreparationFor(current);',
    'await viewReusePreparation.future;',
    'targetComicId: viewReusePreparation.originComicId',
    'onFirstPresentationFrame: versionSource == null',
    '_scheduleReaderMetadataVersionRefresh(',
):
    assert token in reader, token
prepare_start = reader.index('  Future<_PreparedImportedChapter> _prepareImportedChapter(')
prepare_end = reader.index('\n}\n', prepare_start)
assert '_scheduleReaderMetadataVersionRefresh(' not in reader[prepare_start:prepare_end]
for token in (
    '_preferredReusableVersionProofTarget(',
    "'stage': 'version-reuse-preproof-selected'",
    'await _prepareVersionReuseWarmup(versionSource, current);',
    '_scheduleVersionReuseWarmup(versionSource, current);',
):
    assert token not in reader, token

# Warmup remains chapter-generation scoped and never owns version discovery.
# A selected target gets its own single-flight key and filters the relation set
# before any bounded source proof is attempted.
prepare_start = migration.index('  Future<void> _prepareVersionReuseWarmup(')
prepare_end = migration.index('  void _scheduleVersionReuseWarmup(', prepare_start)
prepare = migration[prepare_start:prepare_end]
assert 'ImportedLibraryEntry focus' in prepare
assert 'String? targetComicId' in prepare
assert 'targetComicId: targetComicId' in prepare
assert 'if (targetComicId != null && relatedComicId != targetComicId)' in prepare
assert 'upgradeLegacyIntervalProof: targetComicId != null' in prepare
assert '_ensureSourceVersionReuseAuthority(focus)' in prepare
assert 'findComicVersions' not in prepare

# Focused proof loads at most the related comic/chapter and is only attempted
# when either side has actual READY/partial/hot reusable physical state.
warm_start = migration.index('  Future<void> _warmVersionRelationPageMappings(')
warm_end = migration.index('  String _versionReuseWarmupKey(', warm_start)
warm = migration[warm_start:warm_end]
assert warm.count('source.loadComic(') == 1
assert 'candidate.sequence == focus.chapter.sequence' in warm
assert 'final focusManifest = focus.chapter.toManifest();' in warm
assert warm.count('_chapterHasReusableVersionSourceState(') >= 2
assert 'predecessorManifest' in warm
assert 'successorManifest' in warm

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
assert 'targetComicId: targetComicId' in migration
assert 'finally {' in view
assert '_versionViewReusePreparations.remove(key);' in view
start_begin = migration.index('_startVersionViewReusePreparation(')
start_end = migration.index('_versionViewReusePreparationFor(', start_begin)
start = migration[start_begin:start_end]
assert '.whenComplete(' not in start
assert 'originComicId: currentComicId' in start

# Missing-mapping eligibility is chapter-scoped: it must not enumerate every
# page merely to learn whether READY/partial/hot reusable state exists.
chapter_state_start = migration.index('  Future<bool> _chapterHasReusableVersionSourceState(')
chapter_state_end = migration.index('  Future<void> _warmVersionRelationPageMappings(', chapter_state_start)
chapter_state = migration[chapter_state_start:chapter_state_end]
assert 'hasReusableChapterState(' in chapter_state
assert 'hasReusablePhysicalStateForChapter(chapter)' in chapter_state
assert 'for (final page in chapter.pages)' not in chapter_state
assert 'findExistingReusableKeys(' not in chapter_state

print('version reuse warmup scope: OK')
