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
reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
migration = read('apps/app/lib/demo_home_source_migration.dart')
handoff = read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
transport = read('packages/downloads/lib/src/artifact_cache_transport.dart')

for token in (
    'final int equivalenceMaxEntries;',
    'LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents',
    'void linkEquivalent({',
    'Future<ArtifactCacheLookup?> lookupAuthoritative(',
    '_lookupCandidatesInOrder(id, <DownloadId>[id]',
):
    require(manager, token, 'equivalence-only artifact cache')
for token in (
    'LinkedHashMap<DownloadId, DownloadId> _aliases',
    'DownloadId resolveAlias(',
    'void alias({',
    'bool removeAlias(',
    'Future<bool> rekey({',
    'aliasMaxEntries',
):
    forbid(manager, token, 'hard artifact alias/rekey')

for token in (
    'final Map<DownloadId, DownloadId> mappings;',
    'int registerEquivalences(ArtifactCacheManager cache) {',
    'cache.linkEquivalent(first: entry.key, second: entry.value);',
):
    require(reuse, token, 'verified equivalence plan')
for token in ('Future<int> applyExisting', 'Future<int> rekeyExisting', 'int apply(ArtifactCacheManager cache)'):
    forbid(reuse, token, 'directed artifact mutation plan')

require(
    migration,
    'registeredPageEquivalences +=\n              item.artifactReuse.registerEquivalences(artifactCache);',
    'explicit migration proof registration',
)
forbid(migration, '.applyExisting(artifactCache)', 'explicit migration hard alias snapshot')
require(transport, 'lookup.storageId != id', 'equivalent cache trace attribution')
forbid(transport, 'resolveAlias(', 'artifact transport hard alias dependency')
for token in (
    "action: 'skip-verified-equivalent-durable'",
    'cache.containsBackendExact(',
):
    require(handoff, token, 'equivalent durable no-copy boundary')
forbid(handoff, 'cache.containsBackend(', 'non-exact durable ownership probe')

tests = (
    read('packages/downloads/test/artifact_cache_manager_test.dart')
    + read('packages/downloads/test/artifact_cache_reuse_test.dart')
    + read('packages/downloads/test/promoted_artifact_cache_handoff_test.dart')
)
for token in (
    'verified equivalence reuses a different exact URL artifact',
    'equivalence registration is independent of current artifact existence',
    'reverse proof registration reuses one symmetric equivalence edge',
    'verified equivalent durable artifact avoids Reader-side exact copy',
):
    require(tests, token, 'dev230 behavior coverage')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 230:
    raise SystemExit('App build must be at least 230')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

check = read('tool/check.sh')
require(check, 'test_dev230_remove_hard_artifact_alias.py', 'release gate wiring')

print('dev.230 equivalence-only artifact ownership: OK')
