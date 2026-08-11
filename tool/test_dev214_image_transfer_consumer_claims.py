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

session = read('packages/sessions/lib/src/download_session.dart')
for token in (
    'final class DownloadDemandLease',
    'DownloadDemandLease attachDemand({',
    'final Map<String, int> _demandPriorities',
    'int get demandCount',
    'int get effectivePriority',
    '_demandPriorities.values.reduce',
    'session._detachDemand(scopeId);',
):
    require(session, token, 'scoped transfer demand claim')
forbid(session, '_demandPriorities.values.fold<int>(0,', 'summed demand priority')

registry = read('packages/sessions/lib/src/download_registry.dart')
require(registry, 'initiallyDemanded: false', 'registry sessions start without fake consumer')

job = read('packages/sessions/lib/src/download_job.dart')
for token in ('this.attachLegacyDemand = true', 'if (attachLegacyDemand)'):
    require(job, token, 'legacy direct-download compatibility boundary')

live = read('packages/sessions/lib/src/live_coordinator.dart')
transfer_owner_path = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
transfer_owner = transfer_owner_path.read_text(encoding='utf-8') if transfer_owner_path.exists() else ''
claim_owner = live + transfer_owner
for token in (
    'session.attachDemand(',
    'session.effectivePriority',
    'attachLegacyDemand: false',
):
    require(claim_owner, token, 'Reader claim integration')
if transfer_owner:
    for token in (
        'final Map<DownloadId, Map<String, _TransferClaim>> _claims',
        'existing.lease.updatePriority(demand.priority);',
        'claim?.lease.detach();',
        "reason: 'remaining-consumer'",
    ):
        require(transfer_owner, token, 'composition transfer claim integration')
else:
    for token in (
        'final Map<DownloadId, DownloadDemandLease> _downloadClaims',
        'claim.updatePriority(entry.value.priority);',
        '_downloadClaims.remove(id)?.detach();',
        "reason: 'remaining-consumer'",
    ):
        require(live, token, 'Reader-local claim integration')

regression = read('packages/sessions/test/download_session_test.dart')
require(regression, 'consumer demand claims use max priority and detach independently', 'claim regression')
live_test = read('packages/sessions/test/live_coordinator_test.dart')
require(live_test, 'remaining consumer claim keeps transfer and downgrades priority', 'cancel/priority regression')

# Later phases may lift the physical registry, but dev.214's contract remains:
# there is still one scoped claim per consumer and no second cache/download stack.
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
if transfer_owner:
    require(pipe, '_downloads = _transferRuntime.registry;', 'lifted physical registry boundary')
else:
    require(pipe, '_downloads = DownloadRegistry(', 'dev.214 Reader-local registry boundary')
forbidden_global = (
    'GlobalDownloadRegistry',
    'static final DownloadRegistry',
    'shareSessionPartial',
    'aliasDownloadSession',
)
for token in forbidden_global:
    forbid(pipe + session + registry + transfer_owner, token, 'second/premature transfer owner')

for rel in (
    'docs/adr/0195-image-transfer-consumer-claims-before-registry-lift.md',
    'docs/audits/dev214-image-transfer-consumer-claim-root-cause-audit.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.214 governance file missing: {rel}')

version = read('apps/app/pubspec.yaml')
android = read('apps/app/android/zic-version.properties')
import re
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', version, re.MULTILINE)
android_match = re.search(r'^versionCode=(\d+)$', android, re.MULTILINE)
if version_match is None or int(version_match.group(1)) < 214:
    raise SystemExit('dev.214 app version regression')
if android_match is None or int(android_match.group(1)) < 214:
    raise SystemExit('dev.214 Android version regression')
print('dev.214 image-transfer consumer claims: OK')
