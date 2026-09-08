#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
migration = (ROOT / 'apps/app/lib/demo_home_source_migration.dart').read_text()
reader = (ROOT / 'apps/app/lib/demo_home_reader_route.dart').read_text()
compat = (ROOT / 'apps/app/lib/demo_home_source_compat.dart').read_text()

# Version discovery/presentation owns relation refresh. Opening details must not
# trigger page-media proof work merely because the version button exists.
assert '_scheduleVersionReuseWarmup(' not in compat

# Outside the scheduler's recursive self-call, Reader preparation is the only
# production caller. It passes the hydrated exact chapter, not just comicId.
reader_calls = reader.count('_scheduleVersionReuseWarmup(')
assert reader_calls == 1, reader_calls
assert '_scheduleVersionReuseWarmup(versionSource, current);' in reader

# The scheduler itself is chapter-generation scoped and no longer performs a
# second findComicVersions refresh behind the details/version-state owner.
scheduler = migration[migration.index('  void _scheduleVersionReuseWarmup('):migration.index('  Future<int> _restoreSourceVersionArtifactEquivalences(')]
assert 'ImportedLibraryEntry focus' in scheduler
assert 'focus.chapter.chapterId' in scheduler
assert 'focus.chapter.sourceRevision' in scheduler
assert 'findComicVersions' not in scheduler
assert 'refreshVersions' not in scheduler
assert 'await _restoreSourceVersionArtifactEquivalences(focus);' in scheduler

# Focused proof may inspect the related comic/chapter only; the already-hydrated
# Reader chapter is reused as one side of the proof instead of loading both
# comics and every chapter in the relation.
warm = migration[migration.index('  Future<void> _warmVersionRelationPageMappings('):migration.index('  void _scheduleVersionReuseWarmup(')]
assert 'ImportedLibraryEntry focus' in warm
assert warm.count('source.loadComic(') == 1
assert 'candidate.sequence == focus.chapter.sequence' in warm
assert 'final focusManifest = focus.chapter.toManifest();' in warm
assert 'focus.chapter.chapterId' in warm

# loadVersionState still owns relation discovery, but not page-media proof.
version_state = migration[migration.index('  Future<details.ComicDetailsVersionState> _loadSourceVersionState('):migration.index('  bool _sourceComicHasUpdate(')]
assert 'findComicVersions' in version_state
assert '_scheduleVersionReuseWarmup(' not in version_state

print('version reuse warmup scope: OK')
