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

manager = read('packages/downloads/lib/src/artifact_cache_manager.dart')
for token in (
    'final LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents',
    'void linkEquivalent({',
    'Iterable<DownloadId> _lookupCandidates(DownloadId id) sync* {',
    '_lookupCandidatesInOrder(id, _lookupCandidates(id))',
    'Future<ArtifactCacheLookup?> lookupAuthoritative(DownloadId id)',
    'int get equivalenceCount => _equivalenceOrder.length;',
):
    require(manager, token, 'verified artifact equivalence fallback')

reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
for token in (
    'int registerEquivalences(ArtifactCacheManager cache) {',
    'cache.linkEquivalent(first: entry.key, second: entry.value);',
):
    require(reuse, token, 'verified mapping reuse plan')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 211:
    raise SystemExit('App build must be at least 211')
build = int(version.group(1))
if build >= 229:
    handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
    require(handoff, 'final PartialEquivalentCandidates? equivalentCandidates;', 'verified cold partial reuse boundary')
    forbid(reuse, 'applyDurablePartials', 'eager durable partial copy')
else:
    require(reuse, 'Future<int> applyDurablePartials(PartialDownloadStore store) async {', 'legacy verified partial copy')

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    'Future<int> _restoreSourceVersionArtifactEquivalences(',
    'plan.registerEquivalences(artifactCache)',
    "'stage': 'version-artifact-equivalence-restored'",
    "'equivalentPages': reused",
    "'registeredEquivalentPages': registeredEquivalentPages",
):
    require(migration, token, 'Reader/warmup equivalence registration')
forbid(migration, 'reused += await plan.applyExisting(artifactCache);', 'snapshot-only full artifact reuse')


promoted = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
transport = read('packages/downloads/lib/src/artifact_cache_transport.dart')
require(transport, "'verifiedEquivalentReuse':", 'equivalent reuse trace attribution')
if build >= 230:
    require(promoted, 'cache.containsBackendExact(', 'promoted exact backend ownership')
    require(promoted, "action: 'skip-verified-equivalent-durable'", 'equivalent durable no-copy boundary')
    require(manager, 'backend.openArtifactStream(id)', 'exact backend ownership')
    require(transport, 'lookup.storageId != id', 'equivalent reuse trace attribution')
    for token in ('resolveAlias(', 'Future<bool> rekey({', 'Future<bool> containsBackend({'):
        forbid(manager, token, 'superseded hard alias/rekey backend')
else:
    require(promoted, 'cache.containsBackend(', 'promoted exact backend ownership')
    require(manager, 'backend.openArtifactStream(resolveAlias(id))', 'containsBackend excludes equivalence fallback')
    require(manager, 'final oldLookup = await lookupAuthoritative(oldId);', 'rekey excludes equivalence fallback')
    require(transport, "lookup.storageId != _cache.resolveAlias(id)", 'equivalent reuse trace attribution')

tests = read('packages/downloads/test/artifact_cache_manager_test.dart') + read('packages/downloads/test/artifact_cache_reuse_test.dart')
for token in (
    'verified equivalence observes artifacts promoted after registration',
    'persisted offset registers symmetric future-artifact equivalence',
    'verified equivalence does not satisfy exact backend ownership',
):
    require(tests, token, 'late artifact equivalence regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev211_version_equivalence_late_artifact_reuse.py', 'release gate wiring')

android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.211 version equivalence / late artifact reuse owner: OK')
