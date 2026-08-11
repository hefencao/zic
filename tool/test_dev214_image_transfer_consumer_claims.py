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
for token in (
    'final Map<DownloadId, DownloadDemandLease> _downloadClaims',
    'session.attachDemand(',
    'claim.updatePriority(entry.value.priority);',
    '_downloadClaims.remove(id)?.detach();',
    "reason: 'remaining-consumer'",
    'session.effectivePriority',
    'attachLegacyDemand: false',
):
    require(live, token, 'Reader claim integration')

regression = read('packages/sessions/test/download_session_test.dart')
require(regression, 'consumer demand claims use max priority and detach independently', 'claim regression')
live_test = read('packages/sessions/test/live_coordinator_test.dart')
require(live_test, 'remaining consumer claim keeps transfer and downgrades priority', 'cancel/priority regression')

# dev.214 is deliberately not the registry-lift phase. Do not accidentally claim
# or create a second global transfer/cache owner before native ingress is split.
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
require(pipe, '_downloads = DownloadRegistry(', 'deliberate Reader-local registry boundary')
forbidden_global = (
    'GlobalDownloadRegistry',
    'static final DownloadRegistry',
    'shareSessionPartial',
    'aliasDownloadSession',
)
for token in forbidden_global:
    forbid(pipe + session + registry, token, 'premature global transfer owner')

for rel in (
    'docs/adr/0195-image-transfer-consumer-claims-before-registry-lift.md',
    'docs/audits/dev214-image-transfer-consumer-claim-root-cause-audit.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.214 governance file missing: {rel}')

version = read('apps/app/pubspec.yaml')
android = read('apps/app/android/zic-version.properties')
require(version, 'version: 0.31.0+214', 'dev.214 app version')
require(android, 'versionCode=214', 'dev.214 Android version')
print('dev.214 image-transfer consumer claims: OK')
