#!/usr/bin/env python3
"""Guard dev.246 stable candidate + single-flight destructive preemption."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.246 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.246 contract: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 246:
    raise SystemExit('App build must be >=246')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

lane = 'packages/sessions/lib/src/net_lane.dart'
require(
    lane,
    'Duration preemptionCandidateGrace = Duration.zero',
    'highPrioritySinceMicros',
    '_preemptionCandidateReady(_Pending pending)',
    '_schedulePreemptionCandidateWake(blockedHighPriority);',
    '_hasBodyPermitPreemptionInFlight' if int(m.group(1)) >= 270 else '_hasPreemptionInFlight',
    'task.token.cancelled && task.token.preemptionSnapshot != null',
    'required this.incomingWaitMicros',
)
reject(
    lane,
    'demotionPreemptionGrace',
    'preemptionProtectedUntilMicros',
    '_scheduleDemotionProtectionWake',
    'pressurePreemptionPriorityFloor',
)
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'preemptionCandidateGrace: const Duration(milliseconds: 100)',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'preemptionCandidateGrace:',
)
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    "'incomingWaitMicros': preemption.incomingWaitMicros",
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'transient blocked current does not destructively preempt before candidate grace',
    'stable blocked current preempts after candidate grace',
    'only one destructive preemption may be in flight',
)
for path in (
    'docs/archive/adr/0226-stable-destructive-preemption-transaction.md',
    'docs/archive/audits/dev246-destructive-preemption-burst-root-cause-audit.md',
    'docs/archive/audits/dev246-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.246 governance file: {path}')
require('docs/ARCHITECTURE.md', 'incoming candidate stability', '最多一个preemption victim')
require('docs/SPEC.md', 'incoming candidate stability', '100ms', '一个scheduler-preemption victim')
require('tool/check.sh', 'test_dev246_stable_destructive_preemption_transaction.py')
print('dev.246 stable destructive-preemption transaction: OK')
