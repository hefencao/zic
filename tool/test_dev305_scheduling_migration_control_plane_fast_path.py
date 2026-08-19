#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.305 missing {label}: {token}')

def forbid_between(text: str, start: str, end: str, token: str, label: str) -> None:
    a = text.index(start)
    b = text.index(end, a)
    if token in text[a:b]:
        raise SystemExit(f'dev.305 forbidden {label}: {token}')

download = read('packages/sessions/lib/src/download_session.dart')
coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
transfer = read('packages/sessions/lib/src/download_transfer_owner.dart')
download_test = read('packages/sessions/test/download_session_test.dart')
coordinator_test = read('packages/sessions/test/live_coordinator_test.dart')

require(download, 'if (previous == null) {', 'new-scope lifecycle boundary')
require(download, 'TraceEventKind.demandApplied,', 'new-scope demand trace')
for token in (
    'final Map<DownloadId, DownloadSession> _observedDownloadSessions =',
    'if (session != null && !identical(observed, session))',
    'void _observeDownloadIdentity(',
    'if (diff.added.containsKey(entry.key)) {',
):
    require(coordinator, token, 'identity/scheduling separation')
require(transfer, 'bool _tryUpdateExistingClaimScheduling(',
        'existing physical claim fast path')
for token in (
    'prior.exactId != next.exactId',
    'prior.demand.expectedChecksum != next.demand.expectedChecksum',
    'prior.demand.completionIntent != next.demand.completionIntent',
    '_refreshClaimScheduling(id, session, next.demand);',
):
    require(transfer, token, 'fast-path authority guard')

require(download_test,
        'priority-only demand migration does not emit demand lifecycle trace',
        'priority trace regression')
require(coordinator_test,
        'download priority migration does not re-observe physical identity',
        'source observation regression')
require(coordinator_test,
        'priority-role migration stays aggregate in reconcile trace',
        'aggregate demand trace regression')

# The old added+changed observation fan-out must not return.
if 'final observed = <MapEntry<DownloadId, DownloadDemand>>[' in coordinator:
    raise SystemExit('dev.305 restored added+changed source observation fan-out')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0284-scheduling-migration-control-plane-fast-path.md',
    'docs/audits/dev305-vertical-jank-control-plane-migration-audit.md',
))
for token in ('8.387ms', 'scheduling-only', 'physical session', 'pipelineReconcileTiming'):
    require(all_docs, token, 'governed dev.305 evidence/boundary')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub_match is None or int(pub_match.group(1)) < 305:
    raise SystemExit('dev.305+ app version mismatch')
if android_match is None or int(android_match.group(1)) < 305:
    raise SystemExit('dev.305+ Android version mismatch')

print('dev.305 scheduling migration control-plane fast path: OK')
