#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

catalog = read('packages/catalog/lib/src/source_catalog.dart')
for token in (
    'final class ComicVersionPageMapping {',
    'final int successorOffset;',
    'final List<ComicVersionPageMapping> pageMappings;',
):
    require(catalog, token, 'durable verified page mapping model')

storage = read('packages/storage/lib/src/sqlite_imported_library_store.dart')
for token in (
    'const _schemaVersion = 11;',
    "page_mappings_json TEXT NOT NULL DEFAULT '[]'",
    'void _migrateComicVersionPageMappings(',
    '_comicVersionPageMappingsFromJson(',
):
    require(storage, token, 'SQLite mapping persistence/migration')

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    'void _scheduleVersionReuseWarmup(',
    'Future<void> _warmVersionRelationPageMappings(',
    'VerifiedArtifactReusePlan.matchResolvedRelated(',
    '_sourceResources.verifiedPageReuseIdentity(',
    'Future<int> _ensureSourceVersionReuseAuthority(',
    'hasReusableChapterState(',
    'hasReusablePhysicalStateForChapter(',
    "'restoreMode': 'compact-version-authority'",
    "'stage': 'version-reuse-authority-ready'",
    "'stage': 'version-page-mapping-warmed'",
):
    require(migration, token, 'version metadata warm / compact authority owner')
for token in (
    'artifactCache.linkEquivalent(',
    "'restoreMode': 'vibevenera-existing-cache-alias'",
    "'stage': 'version-artifact-equivalence-restored'",
):
    forbid(migration, token, 'superseded Reader materialized alias restore')
forbid(
    migration,
    'aliases.contains(relation.successorComicId)',
    'confirmed successor hidden by canonical alias collapse',
)

home = read('apps/app/lib/demo_home.dart') + read('apps/app/lib/demo_home_reader_route.dart')
for token in (
    '_versionViewReusePreparationFor(current)',
    'await _prepareVersionReuseWarmup(versionSource, current);',
    '_scheduleReaderMetadataVersionRefresh(versionSource, current);',
):
    require(home, token, 'Reader fast local restore + async refresh')
forbid(
    home,
    'await _prepareSourceVersionArtifactReuse(current);',
    'blocking source-resolved alias preparation before Reader',
)
forbid(home, 'hasConfirmedSuccessor', 'version relation mirrored into sourceUpdateAt')

reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
for token in (
    'factory VerifiedArtifactReusePlan.fromVerifiedOffset({',
):
    require(reuse, token, 'persisted mapping / validatorless durable partial reuse')

job = read('packages/sessions/lib/src/download_job.dart')
for token in (
    'validatorlessRangeProbe',
    '_verifyArtifactOverlap(',
    'range overlap differs from the existing playable partial',
):
    require(job, token, 'partial continuation overlap verification')

reuse_test = read('packages/downloads/test/artifact_cache_reuse_test.dart')
for token in (
    'persisted verified offset restores aliases without a resolver',
):
    require(reuse_test, token, 'dev.210 reuse regression coverage')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 210:
    raise SystemExit('App build must be at least 210')
build = int(version.group(1))
if build >= 229:
    handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
    for token in (
        'this.equivalentCandidates,',
        'final PartialEquivalentCandidates? equivalentCandidates;',
        "action: candidate.equivalent ? 'restored-equivalent' : 'restored'",
        '? const Validators()',
    ):
        require(handoff, token, 'equivalence-aware cold partial restore')
    forbid(migration, '_reuseSourceVersionDurablePartials', 'eager cross-version partial copy')
    forbid(reuse, 'applyDurablePartials', 'reuse-plan durable partial copy')
    require(
        reuse_test + read('packages/downloads/test/partial_download_handoff_test.dart'),
        'verified equivalent cold partial restores without copying exact entry',
        'dev.229 cold partial restore regression coverage',
    )
else:
    require(migration, 'Future<int> _reuseSourceVersionDurablePartials(', 'legacy durable partial copy')
    require(migration, "'stage': 'version-durable-partial-reused'", 'legacy durable partial trace')
    require(reuse, 'Future<int> applyDurablePartials(PartialDownloadStore store) async {', 'legacy durable partial reuse')
    require(reuse, 'validators: const Validators(),', 'legacy cross-version validator clearing')
    require(reuse_test, 'verified partial reuse clears cross-version validators', 'legacy partial reuse regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev210_version_metadata_warm_reader_fast_partial_reuse.py', 'release gate wiring')

android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.210 version metadata warm / Reader fast restore / partial reuse: OK')
