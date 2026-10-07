#!/usr/bin/env python3
"""Guard dev.186 nested Venera previous pressure and source-open stage tracing."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.186 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.186 token: {present}')


require(
    'packages/plugin_host/lib/src/runtime_source_adapter.dart',
    'controlledPreemptionPriorityFloor:',
    '? 780',
    'incoming.priority < controlledPreemptionPriorityFloor',
    'incoming.priority - activeControl.priority < preemptionThreshold',
    'active.preemptRequested = true;',
)
reject(
    'packages/plugin_host/lib/src/runtime_source_adapter.dart',
    'preemptControlledActiveForCurrent',
    'currentPriorityThreshold',
)
require(
    'packages/plugin_host/test/runtime_source_adapter_test.dart',
    'controlled Venera previous pressure preempts lower request-plan work without parallel contexts',
    '_MutableTaskControl(priority: 700)',
    '_MutableTaskControl(priority: 740)',
    '_MutableTaskControl(priority: 780)',
    'controlled Venera previous pressure respects the forty point preemption threshold',
    '_MutableTaskControl(priority: 760)',
    'expect(connection.maxActive, 1);',
)
require(
    'packages/transport/lib/src/transport.dart',
    'Map<String, Object?> diagnostics = const <String, Object?>{}',
    'final Map<String, Object?> diagnostics;',
    'Scheduling, retry and cache policy',
)
require(
    'packages/downloads/lib/src/source_resource_transport.dart',
    'final requestPlanWatch = Stopwatch()..start();',
    'final hostOpenWatch = Stopwatch()..start();',
    "'sourceRequestPlanMicros': requestPlanMicros",
    "'sourceRequestPlanCacheHit': requestPlanCacheHit",
    "'sourceHostOpenMicros': hostOpenMicros",
    "'sourceOpenPath': openPath",
    "'sourceRetryUsed': retryUsed",
)
require(
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    '...response.diagnostics',
    'diagnostics: response.diagnostics',
)
require(
    'packages/downloads/test/source_resource_transport_test.dart',
    'source open exposes request-plan and host-open stage diagnostics',
    "first.diagnostics['sourceRequestPlanCacheHit'], isFalse",
    "second.diagnostics['sourceRequestPlanCacheHit'], isTrue",
)
require(
    'packages/downloads/test/artifact_cache_transport_test.dart',
    "expect(source.payload['sourceRequestPlanMicros'], 1200);",
    "expect(read.payload['sourceHostOpenMicros'], 3400);",
)
require(
    'docs/archive/adr/0169-venera-previous-request-plan-pressure-and-source-open-stages.md',
    'previous=780',
    '单 invocation',
    'sourceRequestPlanMicros',
    'sourceHostOpenMicros',
)
require(
    'docs/archive/audits/dev186-venera-request-plan-pressure-root-cause-audit.md',
    '6.508 ms',
    '5,133.8 ms',
    'Venera',
)
require(
    'CHANGELOG.md',
    '## 0.31.0-dev.186：Venera Previous Request-Plan 压力与 Source-Open 分段观测',
    '`0.31.0+186`',
)
require(
    'docs/NEXT_CHAT_HANDOFF.md',
    '0169-venera-previous-request-plan-pressure-and-source-open-stages.md',
)
require('tool/check.sh', 'test_dev186_venera_previous_pressure_source_open_stages.py')

pubspec = read('apps/app/pubspec.yaml')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.MULTILINE)
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.MULTILINE,
)
if version is None or int(version.group(1)) < 186:
    raise SystemExit('App build is below dev.186')
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode does not match App build')

print('dev.186 Venera previous request-plan pressure / source-open stages: OK')
