#!/usr/bin/env python3
"""Guard dev.248 byte-weighted animation prefetch execution admission."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.248 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.248 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 248:
    raise SystemExit('App build must be >=248')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))

if build >= 249:
    reject(
        'packages/sessions/lib/src/net_lane.dart',
        'speculativeActiveBytes',
        'speculativeBudgetBytes',
        'estimatedTransferBytes',
        '_speculativeBudgetAvailable',
    )
    reject(
        'packages/pipeline/lib/src/demand.dart',
        'estimatedTransferBytes',
        'speculativeBudgetBytes',
    )
    require(
        'packages/pipeline/lib/src/demand.dart',
        'flowTargetFrames',
    )
    require(
        'docs/archive/adr/0228-animated-speculative-byte-weighted-admission.md',
        'Superseded',
    )
else:
    require(
        'packages/pipeline/lib/src/animated_prefetch_policy.dart',
        'minimumForwardPages = 4',
        'minimumBackwardPages = 2',
        'maximumForwardPages = 7',
        'maximumBackwardPages = 3',
        'estimatedBytesFor(int pageIndex)',
        'enforced by NetLane as an execution budget',
    )
    reject(
        'packages/pipeline/lib/src/animated_prefetch_policy.dart',
        'estimated + cost > maxSpeculativeBytes',
    )
    require(
        'packages/pipeline/lib/src/demand.dart',
        'estimatedTransferBytes',
        'speculativeBudgetBytes',
        'speculativeBudgetExemptPriority',
    )
    require(
        'packages/pipeline/lib/src/heuristic_policy.dart',
        'estimatedTransferBytes: animatedBudgeted',
        'speculativeBudgetBytes: animatedBudgeted',
        'speculativeBudgetExemptPriority: animatedBudgeted ? 900',
    )
    require(
        'packages/sessions/lib/src/live_coordinator.dart',
        'estimatedTransferBytes: entry.value.estimatedTransferBytes',
        'speculativeBudgetBytes: entry.value.speculativeBudgetBytes',
    )
    lane = 'packages/sessions/lib/src/net_lane.dart'
    require(
        lane,
        'speculativeActiveBytes',
        'speculativeActiveTasks',
        '_speculativeBudgetAvailable(_Pending pending)',
        'activeBytes + cost <= limit',
        'activeBytes == 0 && cost > limit',
        'priority >= speculativeBudgetExemptPriority',
        '!_speculativeBudgetAvailable(pending)',
    )
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'estimatedTransferBytes: claim.demand.estimatedTransferBytes',
        'speculativeBudgetBytes: claim.demand.speculativeBudgetBytes',
        'net.updateSpeculativeBudget(',
        "'speculativeActiveBytes': net.speculativeActiveBytes",
    )
    require(
        'packages/sessions/test/net_lane_test.dart',
        'speculative byte budget queues eligible animation work without consuming every slot',
        'foreground task keeps speculative cost metadata when it demotes',
    )
    require(
        'packages/pipeline/test/animated_prefetch_policy_test.dart',
        'byte budget does not remove eligible 2/4 or waterline pages',
    )
for path in (
    'docs/archive/adr/0228-animated-speculative-byte-weighted-admission.md',
    'docs/archive/audits/dev248-weighted-animation-prefetch-root-cause-audit.md',
    'docs/archive/audits/dev248-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.248 governance file: {path}')
if build >= 268:
    require('docs/ARCHITECTURE.md', 'frame credit', 'body-read permit')
    require('docs/SPEC.md', 'frame credit', 'body-read permit')
elif build >= 249:
    require('docs/ARCHITECTURE.md', 'frame credit', 'streamBackpressure')
    require('docs/SPEC.md', 'frame credit', 'streamBackpressure')
else:
    require('docs/ARCHITECTURE.md', '最低**预下载资格**窗口', 'NetLane限制同时active')
    require('docs/SPEC.md', '最低预下载资格窗口', 'NetLane约束同时active')
require('tool/check.sh', 'test_dev248_weighted_animation_prefetch_admission.py')
print('dev.248 weighted animation prefetch admission: OK')
