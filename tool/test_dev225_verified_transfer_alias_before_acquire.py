#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.225 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.225 forbidden {label}: {token}')

registry = read('packages/sessions/lib/src/download_registry.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
chapter = read('packages/downloads/lib/src/persistent_chapter_download_service.dart')
test = read('packages/downloads/test/chapter_downloads_test.dart')
pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or android is None:
    raise SystemExit('dev.225 app version missing')
build = int(pub.group(1))

for token in (
    'final Map<DownloadId, DownloadId> _physicalAliases',
    'DownloadId resolvePhysicalId(DownloadId id)',
    'DownloadSession? findExact(DownloadId id)',
    'void aliasPhysical(',
    "'cannot alias an exact identity after its physical session exists'",
    'final physicalId = resolvePhysicalId(id);',
):
    require(registry, token, 'acquire-time physical alias registry')

for token in (
    'typedef TransferIdentityResolver = DownloadId Function(DownloadId exactId);',
    'final TransferIdentityResolver resolveTransferId;',
    'final normalizedResult = _normalizeDemands(',
    'final normalized = normalizedResult.demands;',
    'var physicalId = consumer._resolvedPhysicalIds[logicalId];',
    'physicalId = resolveTransferId(logicalId);',
    'resolvedAdded: resolvedAdded,',
    'required this.exactId,',
    'DownloadId exactId;',
    'final sourceId = claim.exactId;',
    'provider.transportFor(sourceId.canonicalUri)',
    'claim.consumer.downloadBucketFor(claim.exactId)',
):
    require(owner, token, 'physical claim normalization with exact source identity')

# Query/diagnostic helpers must be side-effect-free and may only resolve an
# already-established registry alias. The mutating resolver belongs to acquire.
for token in (
    '_claims[registry.resolvePhysicalId(id)]',
    '_networkTaskKeys[registry.resolvePhysicalId(id)]',
):
    require(owner, token, 'side-effect-free transfer introspection')
if build >= 237:
    require(
        owner,
        '_activeProviderLeases[registry.resolvePhysicalId(id)]',
        'side-effect-free task-scoped provider introspection',
    )
    forbid(owner, '_activeProviderScopes', 'superseded scope-only provider state')
else:
    require(
        owner,
        '_activeProviderScopes[registry.resolvePhysicalId(id)]',
        'historical side-effect-free provider scope introspection',
    )

for token in (
    'resolveTransferId: _resolveTransferIdForAcquire,',
    'DownloadId _resolveTransferIdForAcquire(DownloadId exactId)',
    'for (final equivalent in _verifiedEquivalentCandidates(exactId))',
    'Iterable<DownloadId> _verifiedEquivalentCandidates(DownloadId id)',
    'yield* cache.directEquivalents(id);',
    'if (exact?.demanded == true) return exactId;',
    'bool _canJoinEquivalentSession(DownloadSession session)',
    'session.residentBodyAuthority !=',
    'ByteResponseBodyAuthority.artifactCache',
):
    require(runtime, token, 'verified existing-transfer acquire resolver')

if build >= 233:
    for token in (
        'final candidates = <DownloadId, DownloadSession>{};',
        '..sort(_compareEquivalentPhysicalCandidates);',
        'registry.aliasPhysical(id: exactId, target: selected.key);',
        "'preferred-existing-owner'",
        "'candidateOwners': candidateOwners",
    ):
        require(runtime, token, 'preferred existing verified physical owner selection')
    forbid(runtime, 'rejected-ambiguous-existing-owners', 'third-owner ambiguity fallback')
else:
    for token in (
        'registry.aliasPhysical(id: exactId, target: candidate);',
        'if (candidate != null && candidate != physicalId)',
    ):
        require(runtime, token, 'historical ambiguous existing-owner rejection')

for token in (
    'registry.sharesPhysicalMedia(id, session.id)',
    'await handoff.persist(session, exactId: id);',
    'required exact durable artifact was not materialized',
):
    require(runtime, token, 'exact durable materialization after shared transfer')
forbid(
    runtime,
    'physical transfer artifact is unavailable for exact materialization',
    'superseded physical-anchor durable copy bridge',
)

replace_pos = chapter.index('Map<DownloadId, TransferDemand>.of(pendingDemands),')
get_pos = chapter.index('final session = transferRuntime.sessionFor(id);', replace_pos)
if replace_pos >= get_pos:
    raise SystemExit('dev.225 chapter command still creates exact session before claim acquire')

for token in (
    'verified equivalent chapter joins existing physical transfer before acquire',
    'verified equivalence never merges two already-created physical sessions',
    'service.artifactCacheManager.linkEquivalent(first: oldId, second: newId);',
    'service.transferRuntime.registry.sessions, hasLength(1)',
    'service.artifactStore.openArtifactStream(newId)',
):
    require(test, token, 'verified transfer alias behavior regression')
if build >= 233:
    for token in (
        'fresh verified identity reuses preferred existing physical owner',
        "expect(alias.payload['candidateOwners'], 2);",
        "expect(alias.payload['selection'], 'preferred-existing-owner');",
    ):
        require(test, token, 'multi-owner verified transfer reuse regression')

for rel in (
    'docs/archive/adr/0205-verified-equivalent-transfer-alias-before-acquire.md',
    'docs/archive/audits/dev225-verified-transfer-alias-root-cause-audit.md',
    'docs/archive/audits/dev225-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.225 missing governance: {rel}')

if build < 225:
    raise SystemExit('dev.225 app version mismatch')
if int(android.group(1)) < 225:
    raise SystemExit('dev.225 Android version mismatch')

print('dev.225 verified transfer alias before acquire: OK')
