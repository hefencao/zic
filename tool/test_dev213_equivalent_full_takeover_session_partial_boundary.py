#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'forbidden {label}: {token}')


cache = read('packages/downloads/lib/src/artifact_cache_manager.dart')
for token in (
    'typedef ArtifactPromotionListener = void Function(DownloadId id);',
    'void addPromotionListener(ArtifactPromotionListener listener)',
    'void removePromotionListener(ArtifactPromotionListener listener)',
    'Iterable<DownloadId> directEquivalents(DownloadId id)',
    'await backend.storePromotedArtifact(id: id, bytes: bytes);',
    'listener(id);',
):
    require(cache, token, 'artifact promotion observer')

session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in (
    '_artifactPromotionListener = promotionListener;',
    'artifactCacheManager.addPromotionListener(promotionListener);',
    'artifactCacheManager.directEquivalents(',
    '_downloads.find(equivalent) == null',
    '_coordinator.refreshDownloadForLocalArtifact(',
    '_artifactCacheManager?.removePromotionListener(promotionListener);',
):
    require(session, token, 'Reader late-equivalent takeover wiring')

coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
for token in (
    'void refreshDownloadForLocalArtifact(String sessionId, DownloadId id)',
    "'stage': 'verified-equivalent-promotion-takeover'",
    'net.cancel(taskKey);',
    'session.committedLength',
):
    require(coordinator, token, 'local artifact takeover without session reset')

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    'bool _versionPageMappingIsFresh(',
    'final revalidationNow = DateTime.now().toUtc();',
    '_versionPageMappingIsFresh(currentMapping, revalidationNow)',
    'final plan = await VerifiedArtifactReusePlan.matchResolvedRelated(',
    'verifiedAt: DateTime.now().toUtc(),',
):
    require(migration, token, 'stale mapping strong revalidation')
forbid(
    migration,
    "existing.any(\n        (mapping) =>\n            mapping.predecessorPageCount == predecessorChapter.pageCount",
    'page-count-only stale mapping acceptance',
)

transport = read('packages/downloads/lib/src/artifact_cache_transport.dart')
require(
    transport,
    "'verifiedEquivalentCandidates': verifiedEquivalentCandidates",
    'equivalence coverage diagnostics',
)

manager_test = read('packages/downloads/test/artifact_cache_manager_test.dart')
require(
    manager_test,
    'promotion listeners expose late verified-equivalent availability',
    'promotion-listener Dart regression',
)

# The deliberate boundary: session-partial sharing is not introduced. Cross-version
# partial reuse remains durable/inactive and owned by PartialDownloadStore.
reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
require(reuse, 'openPartialDownload', 'durable partial reuse boundary')
for path in (
    'packages/downloads/lib/src/artifact_cache_manager.dart',
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
):
    text = read(path)
    forbid(text, 'shareSessionPartial', 'cross-version hot partial sharing')
    forbid(text, 'aliasDownloadSession', 'cross-version DownloadSession aliasing')

check = read('tool/check.sh')
require(
    check,
    'test_dev213_equivalent_full_takeover_session_partial_boundary.py',
    'release gate wiring',
)

version = read('apps/app/pubspec.yaml')
require(version, 'version: 0.31.0+213', 'dev.213 app version')
android = read('apps/app/android/zic-version.properties')
require(android, 'versionCode=213', 'dev.213 Android version')

print('dev.213 equivalent-full takeover/session-partial boundary: OK')
