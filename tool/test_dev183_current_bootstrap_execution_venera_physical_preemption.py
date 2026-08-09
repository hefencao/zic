#!/usr/bin/env python3
"""Guard dev.183 current-bootstrap and physical Venera preemption ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.183 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.183 token: {present}')

require(
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    'final acquiredLease = await scheduler.acquire(',
    'lease = acquiredLease;',
    'acquiredLease.release();',
    'schedulerForegroundAcquires = acquiredLease.foreground ? 1 : 0;',
    'acquiredPriority = acquiredLease.priority;',
)

require(
    'packages/sessions/lib/src/net_lane.dart',
    'final class DecodeLane implements TaskLane',
    'final class UploadLane implements TaskLane',
    'int reservedHighPrioritySlots = 0',
    'int highPriorityThreshold = 1 << 30',
    'int preemptionThreshold = 1 << 30',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'decode: DecodeLane(',
    'upload: UploadLane(',
    'reservedHighPrioritySlots: 1',
    'highPriorityThreshold: 1000',
    'preemptionThreshold: 40',
)

require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'bool isStableDecodeRole(PageRole role)',
    'visibleIndexes.contains(entry.key) ||',
    'isStableDecodeRole(entry.value)',
    "'heuristic:static-visible:${role.name}'",
    "'heuristic:static-warm:${role.name}'",
)
reject('packages/pipeline/lib/src/heuristic_policy.dart', 'PageRole.visible')
require(
    'packages/pipeline/test/pipeline_test.dart',
    'static evidence does not widen stable decode window into far pages',
)
require(
    'packages/pipeline/test/vertical_visible_policy_test.dart',
    'heuristic:static-visible:next',
)

require(
    'packages/sessions/lib/src/decode_refill_policy.dart',
    'Current bootstrap is authoritative',
    'final bootstrapTarget = demand.targetWatermark.clamp(0, 3).toInt();',
    "stage: bootstrapTarget == 1 ? 'one>0' : 'c>2'",
    'return transitionFirstFrame();',
)
require(
    'packages/sessions/test/decode_refill_policy_test.dart',
    'current source wait suppresses speculative neighbor decode bootstrap',
    'transition may bootstrap while current is waiting for source',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'decode lane reserves one handoff for current and preempts lower work',
    'upload lane keeps reserved handoff exclusive to current priority',
)

venera_path = 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
venera = read(venera_path)
for token in (
    'private val cancelledRequests = ConcurrentHashMap.newKeySet<String>()',
    'bridge.finishedSink = finishedSink@ { requestId ->',
    'if (cancelledRequests.remove(requestId)) {',
    'override fun cancel(requestId: String) {',
    'cancelledRequests.add(requestId)',
    'bridge.cancel(requestId)',
    'webView.evaluateJavascript("__zicCancel(${requestId.jsQuoted()});", null)',
    'finishedSink?.invoke(requestId)',
):
    if token not in venera:
        raise SystemExit(f'{venera_path} missing dev.183 contract: {token}')

cancel_start = venera.index('override fun cancel(requestId: String) {')
cancel_end = venera.index('\n    override fun close()', cancel_start)
cancel_block = venera[cancel_start:cancel_end]
if 'pending.remove(requestId)' in cancel_block:
    raise SystemExit('Venera cancel still releases the Dart invocation before physical JS finish')
if cancel_block.index('bridge.cancel(requestId)') > cancel_block.index('evaluateJavascript'):
    raise SystemExit('Venera cancel must abort request-scoped native I/O before JS cancellation')

require(
    'packages/plugin_host/test/runtime_source_adapter_test.dart',
    'controlled Venera preemption keeps the single permit until the physical invocation exits',
    '_PriorityResolveConnection(releaseOnCancel: false)',
    'connection.finishFirst();',
)
require(
    'tool/test_dev119_prefetch_wake_static_retention.py',
    'current source wait suppresses speculative neighbor decode bootstrap',
)
require(
    'tool/test_venera_reader_preflight.py',
    'reservedHighPrioritySlots: 1',
    'highPriorityThreshold: 1000',
)
require('tool/check.sh', 'test_dev183_current_bootstrap_execution_venera_physical_preemption.py')

pubspec = read('apps/app/pubspec.yaml')
version_match = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.MULTILINE)
if not version_match or int(version_match.group(1)) < 183:
    raise SystemExit('app version is below dev.183')
android = read('apps/app/android/zic-version.properties')
android_match = re.search(r'^versionCode=(\d+)\s*$', android, re.MULTILINE)
if (
    android_match is None
    or int(android_match.group(1)) < 183
    or android_match.group(1) != version_match.group(1)
):
    raise SystemExit('Android versionCode is below dev.183 or mismatched with App build')

print('dev.183 current bootstrap / execution reservation / physical Venera preemption: OK')
