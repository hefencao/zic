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
        raise SystemExit(f'forbidden {label}: {token}')



version = read('apps/app/pubspec.yaml')
build_match = re.search(r'^version:\s*0\.31\.0\+(\d+)$', version, re.M)
if build_match is None:
    raise SystemExit('dev.213 app version missing')
build = int(build_match.group(1))

cache = read('packages/downloads/lib/src/artifact_cache_manager.dart')
for token in (
    'Iterable<DownloadId> directEquivalents(DownloadId id)',
    'await backend.storePromotedArtifact(id: id, bytes: bytes);',
):
    require(cache, token, 'verified artifact equivalence')
if build >= 228:
    for token in (
        'typedef ArtifactPromotionListener = void Function(DownloadId id);',
        'void addPromotionListener(ArtifactPromotionListener listener)',
        'void removePromotionListener(ArtifactPromotionListener listener)',
        '_promotionListeners',
    ):
        forbid(cache, token, 'retired late-promotion observer API')
else:
    for token in (
        'typedef ArtifactPromotionListener = void Function(DownloadId id);',
        'void addPromotionListener(ArtifactPromotionListener listener)',
        'void removePromotionListener(ArtifactPromotionListener listener)',
        'listener(id);',
    ):
        require(cache, token, 'artifact promotion observer')

session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
transfer_runtime_path = ROOT / 'packages/downloads/lib/src/composition_download_transfer_runtime.dart'
if transfer_runtime_path.exists():
    transfer_runtime = transfer_runtime_path.read_text(encoding='utf-8')
    if build >= 228:
        for token in (
            'artifactPromotionListener',
            'cache.addPromotionListener(listener);',
            'cache.directEquivalents(promoted)',
            'owner.refreshIndependentExactForPromotedEquivalent(equivalent);',
            'removePromotionListener',
        ):
            forbid(transfer_runtime, token, 'retired composition late-takeover wiring')
        for token in (
            'cache.directEquivalents(exactId)',
            'registry.aliasPhysical(id: exactId, target: candidate);',
            "'stage': 'verified-transfer-acquire-alias'",
        ):
            require(transfer_runtime, token, 'acquire-time verified transfer identity')
    elif build >= 226:
        for token in (
            'artifactPromotionListener = listener;',
            'cache.addPromotionListener(listener);',
            'cache.directEquivalents(promoted)',
            'registry.findExact(equivalent)',
            'owner.refreshIndependentExactForPromotedEquivalent(equivalent);',
            'artifactCacheManager?.removePromotionListener(promotionListener);',
        ):
            require(transfer_runtime, token, 'composition late-equivalent compatibility wiring')
    else:
        for token in (
            'artifactPromotionListener = listener;',
            'cache.addPromotionListener(listener);',
            'cache.directEquivalents(promoted)',
            'registry.find(equivalent) == null',
            'owner.refreshForLocalArtifact(equivalent);',
            'artifactCacheManager?.removePromotionListener(promotionListener);',
        ):
            require(transfer_runtime, token, 'composition late-equivalent takeover wiring')
elif '_PipelineDownloadTransferRuntime' in session:
    for token in (
        'artifactPromotionListener = listener;',
        'cache.addPromotionListener(listener);',
        'cache.directEquivalents(promoted)',
        'registry.find(equivalent) == null',
        'owner.refreshForLocalArtifact(equivalent);',
        'artifactCacheManager?.removePromotionListener(promotionListener);',
    ):
        require(session, token, 'composition late-equivalent takeover wiring')
else:
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
owner_path = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
takeover_owner = owner_path.read_text(encoding='utf-8') if owner_path.exists() else coordinator
if build >= 228:
    for token in (
        "'stage': 'verified-equivalent-promotion-takeover'",
        'refreshIndependentExactForPromotedEquivalent',
        "'compatibilityScope': 'independent-exact-session'",
    ):
        forbid(takeover_owner, token, 'retired late-equivalent takeover')
    forbid(
        coordinator,
        'refreshDownloadForLocalArtifact',
        'dead Reader takeover delegation after composition ownership',
    )
else:
    for token in (
        "'stage': 'verified-equivalent-promotion-takeover'",
        'net.cancel(taskKey);',
        'session.committedLength',
    ):
        require(takeover_owner, token, 'local artifact takeover without session reset')
    if build >= 226:
        forbid(
            coordinator,
            'refreshDownloadForLocalArtifact',
            'dead Reader takeover delegation after composition ownership',
        )
        require(
            takeover_owner,
            "'compatibilityScope': 'independent-exact-session'",
            'late takeover compatibility scope',
        )
    else:
        require(
            coordinator,
            'void refreshDownloadForLocalArtifact(String sessionId, DownloadId id)',
            'Reader takeover delegation',
        )

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
if build >= 228:
    forbid(
        manager_test,
        'promotion listeners expose late verified-equivalent availability',
        'retired promotion-listener Dart regression',
    )
else:
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

if build < 213:
    raise SystemExit('dev.213 app version regressed')
android = read('apps/app/android/zic-version.properties')
if f'versionCode={build}' not in android:
    raise SystemExit('dev.213 Android versionCode mismatch')

print('dev.213 equivalent-full takeover/session-partial boundary: OK')
