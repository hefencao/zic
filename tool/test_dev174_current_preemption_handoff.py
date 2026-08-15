#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


version_match = re.search(
    r'^version:\s*0\.31\.0\+(\d+)\s*$',
    read('apps/app/pubspec.yaml'),
    re.M,
)
build = int(version_match.group(1)) if version_match is not None else 0

lane = read('packages/sessions/lib/src/net_lane.dart')
for token in (
    'final blockedHighPriority = _highestBlockedHighPriorityPending();',
    '_preemptLowestRunningFor(blockedHighPriority)',
    '_Pending? _highestBlockedHighPriorityPending()',
    'pending.priority < highPriorityThreshold',
    '!_needsHandoff(pending)',
    'if (!task.preemptible || task.token.cancelled) continue;',
):
    require(lane, token, 'saturated handoff preemption owner')

# The handoff slot stays bounded across both body-read permits and retained
# transport leases. A parked response may release the former without exiting,
# so pending admission must guard both physical resources independently.
require(
    lane,
    'if (handoff &&\n            (reservedHighPrioritySlots <= 0 ||\n                _receivingActive >= handoffCapacity ||\n                _transportLeasesActive >= handoffCapacity)) {\n          return false;',
    'bounded max+reserved admission',
)
require(
    lane,
    ').whenComplete(() {\n          final removed = _active.remove(next.key);',
    'physical task identity released only on task completion',
)

test = read('packages/sessions/test/net_lane_test.dart')
if build >= 245:
    for token in (
        'blocked current preempts only after reserved headroom is occupied',
        'maxActive: 5,',
        'reservedHighPrioritySlots: 1,',
        "key: 'current-a'",
        "key: 'current-b'",
        'await lowestCancelled.future.timeout',
        'await secondCurrentStarted.future.timeout',
        'expect(firstCurrentRelease.isCompleted, isFalse);',
    ):
        require(test, token, 'borrow-first saturated current regression')
else:
    for token in (
        'blocked current keeps preempting low work while the handoff slot unwinds',
        'maxActive: 5,',
        'reservedHighPrioritySlots: 1,',
        "key: 'current-a'",
        "key: 'current-b'",
        'await prefetchCancelled[1]!.future;',
        'await secondCurrentStarted.future;',
        'expect(stuckRelease.isCompleted, isFalse);',
    ):
        require(test, token, '5+1 current-preemption regression')

profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
require(profile, 'networkConcurrency: 5', 'stable network concurrency')
composition = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in (
    'reservedHighPrioritySlots: 1',
    'highPriorityThreshold: 1000',
    'preemptionThreshold: 40',
):
    require(composition, token, 'stable Reader network policy')

check = read('tool/check.sh')
require(check, 'test_dev174_current_preemption_handoff.py', 'release gate wiring')

version = re.search(
    r'^version:\s*0\.31\.0\+(\d+)\s*$',
    read('apps/app/pubspec.yaml'),
    re.M,
)
if version is None or int(version.group(1)) < 174:
    raise SystemExit('App build must be at least 174')
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.M,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.174 current preemption handoff contract: OK')
