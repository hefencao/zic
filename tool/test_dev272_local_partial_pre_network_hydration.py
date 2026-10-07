#!/usr/bin/env python3
"""Guard dev.272 local physical hydration before NetLane admission."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def req(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit('FAIL: ' + message)

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    req(not missing, f'{path} missing dev.272 contract: {missing}')

pub = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 272, 'App build must be >=272')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

owner_path = 'packages/sessions/lib/src/download_transfer_owner.dart'
owner = read(owner_path)
require(
    owner_path,
    'final Map<DownloadId, Future<void>> _localPreparations',
    '_locallyPreparedSessions',
    'void _startLocalPreparation(',
    'Future<void> _runLocalPreparation(',
    'prepare!(session);',
    "'stage': 'physical-local-prepare'",
    "'action': 'local-hydration-failed-network-fallback'",
    "'action': completedLocally",
    "? 'local-completion-short-circuit'",
    "? 'local-hydration-ready'",
    '_localPreparations.containsKey(physicalId)',
)
ensure_start = owner.index('void _ensureDownloadTask(')
run_start = owner.index('Future<void> _runDownload(', ensure_start)
ensure = owner[ensure_start:run_start]
req('_startLocalPreparation(' in ensure,
    'fresh cold physical session must start local preparation from _ensureDownloadTask')
req("final taskKey = 'transfer:${++_taskSequence}:${id.key}';" in ensure,
    'network task creation marker missing')
req(ensure.index('_startLocalPreparation(') <
    ensure.index("final taskKey = 'transfer:${++_taskSequence}:${id.key}';"),
    'local preparation must start before NetLane task creation')
run = owner[run_start:]
req('prepare(session);' not in run.split('bool _scheduleDownloadRetry(', 1)[0],
    '_runDownload must not re-own cold local prepare behind NetLane admission')
req('prepareDownload' not in run.split('bool _scheduleDownloadRetry(', 1)[0],
    'provider/network attempt must not invoke local durable prepare')

require(
    'packages/sessions/test/download_transfer_owner_test.dart',
    'cold local prepare hydrates physical partial before NetLane admission',
    'failed local prepare falls back to provider once without prepare loop',
    'expect(session.committedLength, partial.length);',
    'expect(transport.opens, 0);',
    'expect(prepareCalls, 1);',
)

require(
    'packages/downloads/lib/src/partial_download_handoff.dart',
    'final ArtifactCacheReadScheduler? readScheduler;',
    'priority: () => session.effectivePriority',
    'lease = await scheduler.acquire(',
    'priority: priority,',
    '_moveNextCancellable(iterator',
    'lease?.release();',
)
require(
    'packages/downloads/lib/src/composition_download_transfer_runtime.dart',
    'final ArtifactCacheReadScheduler localReadScheduler;',
    'readScheduler: localReadScheduler,',
    'localReadScheduler: localReadScheduler,',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'localReadScheduler: artifactReadScheduler,',
    'final localReadScheduler = transferRuntime.localReadScheduler;',
)
require(
    'packages/downloads/test/partial_download_handoff_test.dart',
    'cold partial hydration uses the shared persistent read scheduler',
    'expect(activeWhileReading, 1);',
    'expect(scheduler.activeCount, 0);',
)

for path in (
    'docs/archive/adr/0250-local-partial-hydration-before-network-admission.md',
    'docs/archive/audits/dev272-local-partial-hydration-admission-root-cause-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.272 governance file: {path}')
require('docs/ARCHITECTURE.md', 'physical local prepare', '在任何NetLane task/transport lease/provider lookup之前启动')
require('docs/SPEC.md', '该local prepare MUST在NetLane transport/source admission之前')
require('docs/IMPLEMENTATION_STATUS.md', 'physical-local-prepare', 'local-prepare operation', 'max2')
require('docs/NEXT_CHAT_HANDOFF.md', 'physical-local-prepare', 'max2', 'NetLane task')
require('CHANGELOG.md', '0.31.0-dev.272', 'NetLane transport admission前移')
require('tool/check.sh', 'test_dev272_local_partial_pre_network_hydration.py')

# Frozen policy boundaries are not a fix target for local hydration ordering.
require('packages/pipeline/lib/src/animated_prefetch_policy.dart',
        'if (readDistance == 1) return 5;',
        'if (readDistance == 2) return 3;',
        'if (readDistance == -1) return 2;')
require('packages/downloads/lib/src/download_resource_coordinator.dart',
        'reservedHighPrioritySlots: 1')

print('PASS: dev.272 local partial hydration before network admission')
