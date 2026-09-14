#!/usr/bin/env python3
"""Guard dev.276 Venera current-handoff active-priority preemption closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)


def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.276 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 276, 'dev.276 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 276, 'dev.276 Android version missing')

adapter = text('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for marker in (
    'StreamSubscription<int>? prioritySubscription;',
    'final crossedCurrentThresholdDown =',
    'observedPriority >= dynamicPreemptionPriorityThreshold',
    'priority < dynamicPreemptionPriorityThreshold',
    'final waiter = _highestPriorityWaiter();',
    'waiter.priority < dynamicPreemptionPriorityThreshold',
    '_maybePreemptActiveForControlled(waiter.control);',
    'activeInvocation.disposePrioritySubscription();',
):
    req(marker in adapter, f'active current handoff closure missing: {marker}')

# Single-context ownership and the existing threshold remain authoritative.
require(
    'packages/plugin_host/lib/src/runtime_source_adapter.dart',
    'this.preemptionThreshold = 40',
    'maxConcurrentInvocations == 1',
)
require('packages/plugin_host/lib/src/runtime_executors.dart', 'maxConcurrentInvocations: 1')

tests = text('packages/plugin_host/test/runtime_source_adapter_test.dart')
for marker in (
    'active Venera current handoff re-evaluates preemption when the old current demotes',
    'oldCurrentControl = _MutableTaskControl(priority: 1000)',
    'newCurrentControl = _MutableTaskControl(priority: 1000)',
    'oldCurrentControl.updatePriority(820)',
    'active Venera demotion does not turn viewport jitter into plan preemption',
):
    req(marker in tests, f'dev.276 runtime regression missing: {marker}')

for path in (
    'docs/adr/0254-venera-current-handoff-active-priority.md',
    'docs/audits/dev276-venera-current-handoff-gate-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.276 governance file: {path}')

require('docs/ARCHITECTURE.md', 'active current-class demotion', '同一40分preemption')
require('docs/SPEC.md', 'controlled active从current=1000向下跨出', '非current active demotion')
require('docs/IMPLEMENTATION_STATUS.md', 'active current-class demotion', 'gate wait', '40分')
require('docs/NEXT_CHAT_HANDOFF.md', 'active current-class demotion', '新current waiter', '40分')
require('CHANGELOG.md', '0.31.0-dev.276', 'active')

print('PASS: dev.276 Venera current handoff gate priority closure')
