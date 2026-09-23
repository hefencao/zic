#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/home_shell_source_migration.dart').read_text()
reader = (ROOT / 'apps/app/lib/home_shell_reader_route.dart').read_text()
compat = (ROOT / 'apps/app/lib/home_shell_source_compat.dart').read_text()
lifecycle = (ROOT / 'apps/app/lib/home_version_reuse_lifecycle.dart').read_text()
composition = (ROOT / 'apps/app/lib/home_reader_composition.dart').read_text()

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
):
    assert token in migration, token
for token in (
    'onFirstPresentationFrame: versionSource == null',
    '_scheduleReaderMetadataVersionRefresh(',
):
    assert token in reader, token
assert 'final authorityMappingCount = await _prepareVersionAuthority(current);' in composition
assert '_scheduleReaderMetadataVersionRefresh(' not in composition
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
prepare_start = lifecycle.index('  Future<void> prepareWarmup(')
prepare_end = lifecycle.index('  Future<void> _runWarmup(', prepare_start)
prepare = lifecycle[prepare_start:prepare_end]
run_start = lifecycle.index('  Future<void> _runWarmup(', prepare_end)
run_end = lifecycle.index('  void scheduleReaderMetadataVersionRefresh(', run_start)
run = lifecycle[run_start:run_end]
assert 'ImportedLibraryEntry focus' in prepare
assert 'String? targetComicId' in prepare
assert 'targetComicId: targetComicId' in prepare
assert 'if (targetComicId != null && relatedComicId != targetComicId)' in run
assert 'upgradeLegacyIntervalProof: targetComicId != null' in run
assert 'findComicVersions' not in run

# Focused proof loads at most the related comic/chapter and is only attempted
# when either side has actual READY/partial/hot reusable physical state.
warm_start = lifecycle.index('  Future<void> _warmRelationPageMappings(')
warm_end = lifecycle.index('  String _viewPreparationKey(', warm_start)
warm = lifecycle[warm_start:warm_end]
assert warm.count('source.loadComic(') == 1
assert 'candidate.sequence == focus.chapter.sequence' in warm
assert 'final focusManifest = focus.chapter.toManifest();' in warm
assert warm.count('_chapterHasReusableSourceState(') >= 2
assert 'predecessorManifest' in warm
assert 'successorManifest' in warm

# Version-state refresh is allowed to warm cached-page matching just like
# VibeVenera details, while explicit "view version" carries the same Future to
# a quickly-entered Reader instead of racing it.
version_state_start = migration.index('  Future<details.ComicDetailsVersionState> _loadSourceVersionState(')
version_state_end = migration.index('  bool _sourceComicHasUpdate(', version_state_start)
version_state = migration[version_state_start:version_state_end]
assert '_versionReuseLifecycle.loadVersionState(' in version_state
assert 'findComicVersions' not in version_state
assert 'Future<HomeVersionState> loadVersionState(' in lifecycle

view_start = migration.index('  Future<void> _viewSourceVersion(')
view_end = migration.index('  Future<void> _migrateSourceVersion(', view_start)
view = migration[view_start:view_end]
assert '_startVersionViewReusePreparation(' in view
assert '_versionReuseLifecycle.finishViewPreparation(' in view
assert 'finally {' in view
assert '_versionViewReusePreparations' not in migration

start_begin = lifecycle.index('  HomeVersionViewPreparation startViewPreparation(')
start_end = lifecycle.index('  HomeVersionViewPreparation? viewPreparationFor(', start_begin)
start = lifecycle[start_begin:start_end]
assert '_viewPreparations[key]' in start
assert 'targetComicId: targetComicId' in start
assert 'originComicId: currentComicId' in start
assert '.whenComplete(' not in start
assert '_viewPreparations.clear();' in lifecycle

# Missing-mapping eligibility is chapter-scoped: it must not enumerate every
# page merely to learn whether READY/partial/hot reusable state exists.
chapter_state_start = lifecycle.index('  Future<bool> _chapterHasReusableSourceState(')
chapter_state_end = lifecycle.index('  Future<void> _warmRelationPageMappings(', chapter_state_start)
chapter_state = lifecycle[chapter_state_start:chapter_state_end]
assert 'hasReusableChapterState(' in chapter_state
assert 'hasReusablePhysicalStateForChapter(chapter)' in chapter_state
assert 'for (final page in chapter.pages)' not in chapter_state
assert 'findExistingReusableKeys(' not in chapter_state

print('version reuse warmup scope: OK')
