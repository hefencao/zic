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
chapter = read('packages/downloads/lib/src/chapter_downloads.dart')
test = read('packages/downloads/test/chapter_downloads_test.dart')

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
    'final normalized = _normalizeDemands(desired);',
    'final physicalId = resolveTransferId(entry.key);',
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
    '_activeProviderScopes[registry.resolvePhysicalId(id)]',
    '_networkTaskKeys[registry.resolvePhysicalId(id)]',
):
    require(owner, token, 'side-effect-free transfer introspection')

for token in (
    'resolveTransferId: _resolveTransferIdForAcquire,',
    'DownloadId _resolveTransferIdForAcquire(DownloadId exactId)',
    'for (final equivalent in cache.directEquivalents(exactId))',
    'if (registry.findExact(exactId) != null) return exactId;',
    'registry.aliasPhysical(id: exactId, target: candidate);',
    'bool _canJoinEquivalentSession(DownloadSession session)',
    'session.residentBodyAuthority !=',
    'ByteResponseBodyAuthority.artifactCache',
    'if (candidate != null && candidate != physicalId)',
):
    require(runtime, token, 'verified existing-transfer acquire resolver')

for token in (
    'await handoff.persist(session);',
    'if (id == session.id) return;',
    'registry.isPhysicalAlias(id, session.id)',
    'await cache.storePromotedArtifact(id: id, bytes: read.bytes);',
):
    require(runtime, token, 'exact durable materialization after shared transfer')

replace_pos = chapter.index('consumer.replaceDemands(\n          identity,')
get_pos = chapter.index('final session = transferRuntime.registry.get(id);', replace_pos)
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

for rel in (
    'docs/adr/0205-verified-equivalent-transfer-alias-before-acquire.md',
    'docs/audits/dev225-verified-transfer-alias-root-cause-audit.md',
    'docs/audits/dev225-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.225 missing governance: {rel}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 225:
    raise SystemExit('dev.225 app version mismatch')
if android is None or int(android.group(1)) < 225:
    raise SystemExit('dev.225 Android version mismatch')

print('dev.225 verified transfer alias before acquire: OK')
