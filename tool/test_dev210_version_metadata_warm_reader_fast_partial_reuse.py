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
    'final class VerifiedComicVersionPageInterval {',
    'final class ComicVersionPageMapping {',
    'final List<VerifiedComicVersionPageInterval> verifiedIntervals;',
    'List<VerifiedComicVersionPageInterval> get effectiveVerifiedIntervals',
    'int? uniqueVerifiedPredecessorIndexForSuccessor(int index)',
    'final int successorOffset;',
    'final List<ComicVersionPageMapping> pageMappings;',
):
    require(catalog, token, 'durable verified affine interval mapping model')

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
    'VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(',
    '_sourceResources.verifiedPageReuseIdentity(',
    'Future<int> _ensureSourceVersionReuseAuthority(',
    'hasReusableChapterState(',
    'hasReusablePhysicalStateForChapter(',
    "'restoreMode': 'canonical-media-direct'",
    "'stage': 'version-reuse-authority-ready'",
    "'stage': 'version-page-mapping-warmed'",
    'verifiedIntervals: intervalProof.verifiedIntervals',
    "'verificationMode': 'bounded-affine-probe'",
    "'verifiedCoveragePages': mapping.verifiedIntervals.fold<int>(",
    'mapping.effectiveVerifiedIntervals',
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
    'await viewReusePreparation.future;',
    'targetComicId: viewReusePreparation.originComicId',
    'onFirstPresentationFrame: versionSource == null',
    '_scheduleReaderMetadataVersionRefresh(',
):
    require(home, token, 'Reader fast local restore + post-presentation async refresh')
prepare_start = home.index('  Future<_PreparedImportedChapter> _prepareImportedChapter(')
prepare_end = home.index('\n}\n', prepare_start)
forbid(
    home[prepare_start:prepare_end],
    '_scheduleReaderMetadataVersionRefresh(',
    'metadata/version discovery competing with first-page source plan',
)
forbid(
    home,
    'await _prepareVersionReuseWarmup(versionSource, current);',
    'generic history warmup blocking ordinary Reader entry',
)
forbid(
    home,
    'await _prepareSourceVersionArtifactReuse(current);',
    'blocking source-resolved alias preparation before Reader',
)
forbid(home, 'hasConfirmedSuccessor', 'version relation mirrored into sourceUpdateAt')

reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
for token in (
    'factory VerifiedArtifactReusePlan.fromVerifiedOffset({',
    'static Future<VerifiedArtifactIntervalProof?> matchResolvedRelatedIntervals({',
    'int maxProbeCount = 8,',
    'final targetIndex = id.pageIndexHint;',
    'hintedPage.pageId != id.content.pageId',
    'hintedPage.uri != id.canonicalUri',
):
    require(reuse, token, 'persisted mapping / O(1) page-index resolver')
forbid(reuse, '_targetIndexes', 'whole-chapter resolver page index table')
forbid(reuse, '_ExactPageLocator', 'whole-chapter resolver page locator map')

domain_identity = read('packages/domain/lib/src/identity.dart')
for token in (
    'this.pageIndexHint,',
    'final int? pageIndexHint;',
    'This is deliberately excluded from [key], JSON persistence,',
):
    require(domain_identity, token, 'non-identity page index execution hint')
reader_identity = read('packages/downloads/lib/src/reader_page_identity.dart')
require(reader_identity, 'pageIndexHint: asset.index,', 'manifest-aware page index hint publication')

home_session = read('apps/app/lib/home_library_session.dart')
for token in (
    'mapping.effectiveVerifiedIntervals',
    'verifiedIntervals: mapping.effectiveVerifiedIntervals',
    'addVerifiedInterval(',
):
    require(home_session, token, 'interval-scoped version authority publication')

downloads = read('packages/downloads/lib/src/chapter_downloads.dart')
record_start = downloads.index('  Future<({CacheRec record, String proof})?> _resolveReusablePageRecord(')
record_end = downloads.index('  /// Lifecycle-edge diagnostic trail only', record_start)
record_reuse = downloads[record_start:record_end]
require(
    record_reuse,
    'mapping.uniqueVerifiedPredecessorIndexForSuccessor(pageIndex)',
    'manual download interval-scoped byte reuse',
)
forbid(
    record_reuse,
    'pageIndex - mapping.successorOffset',
    'manual download global-offset byte reuse',
)

baseline = read('packages/catalog/lib/src/comic_version_baseline.dart')
for token in (
    '// Cache/hot reuse no longer composes A->B->C into pairwise runtime',
    'for (final relation in outgoing[node(sourceId, predecessor)] ??',
    'directCacheReuseRelations.add(',
):
    require(baseline, token, 'direct-only transitional cache relation projection')
for token in (
    'for (var leftIndex = 0; leftIndex < cacheMembers.length; leftIndex++)',
    'final left = cacheMembers[leftIndex];',
):
    forbid(baseline, token, 'synthetic multi-hop cache relation composition')
# Download-head management may still compose a unique historical path; that is
# separate from Reader/cache physical ownership.
require(
    baseline,
    'List<VerifiedComicVersionPageInterval> composeVerifiedIntervals(',
    'download-head historical proof composition',
)

source_transport = read('packages/downloads/lib/src/source_resource_transport.dart')
for token in (
    "'sourceVerifiedReuseIdentity': verifiedReuseIdentity",
    'if (!request.requiresRuntimeTransform)',
    'verifiedComicResourceIdentity(request.uri)',
):
    require(source_transport, token, 'normal-open strong reuse evidence')

chapter_downloads = read('packages/downloads/lib/src/chapter_downloads.dart')
for token in (
    'typedef ChapterVerifiedPageReuseObserver =',
    'void Function(ChapterManifest manifest, PageAsset page, String identity);',
    'this.onVerifiedPageReuseIdentity,',
    "response.diagnostics['sourceVerifiedReuseIdentity']",
    '_resourceAccess?.onVerifiedPageReuseIdentity?.call(',
):
    require(chapter_downloads, token, 'manifest-aware natural reuse evidence bridge')

home_session = read('apps/app/lib/home_library_session.dart')
for token in (
    'static const int _versionReuseObservationLimit = 1024;',
    'void observeVerifiedPageReuseIdentity(',
    '_uniqueObservedRelatedPage(',
    'mapping.recordVerifiedPageMatch(',
    'mapping.recordVerifiedPageMismatch(',
    'if (identical(updated, mapping)) continue;',
    'await upsertVersionRelationDerivedState(',
    'Future<void> flushVersionReuseEvidence()',
):
    require(home_session, token, 'bounded incremental version interval evidence')
forbid(
    home_session,
    'verifiedPageReuseIdentity(',
    'Home evidence owner performing source resolution',
)
for token in (
    'ComicVersionCanonicalMediaLedger _canonicalMediaLedger',
    'Future<void> _assimilateCanonicalMediaRelationsNow(',
    'persistCanonicalMediaProjections(',
    'final ranges = <CanonicalMediaActiveRange>[',
    "runtime.replaceCanonicalMediaAuthorityScope(",
):
    require(home_session, token, 'canonical media projection / active proof owner')

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
