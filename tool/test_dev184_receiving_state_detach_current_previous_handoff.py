#!/usr/bin/env python3
"""Guard dev.184 receiving-state detach and current/previous handoff ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.184 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.184 token: {present}')


require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'final taskIsActive = taskKey != null && net.isActive(taskKey);',
    'final receiving = session?.state == DownloadState.receiving;',
    'if (receiving && taskIsActive) {',
    "reason: 'retained-background'",
    'else if (taskKey != null && taskIsActive) {',
    'net.cancel(taskKey);',
    'net.cancelQueued(taskKey);',
)
reject(
    'packages/sessions/lib/src/live_coordinator.dart',
    'if (session?.activeRun == true && taskKey != null) {',
)

require(
    'packages/sessions/test/live_coordinator_test.dart',
    'active nonresumable transfer survives window detach and is not reopened',
    'expect(registry.find(id)?.state, DownloadState.receiving);',
    'detached pre-open run yields its slot to adjacent previous',
    'expect(openingSession?.state, DownloadState.queued);',
    'await opening.cancelled.future.timeout',
    'await previous.opened.future.timeout',
    'role: PageRole.previous,',
    'priority: 780,',
)

require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'PageRole.current => 1000',
    'PageRole.previous => 780',
)
require(
    'docs/adr/0167-receiving-state-detach-current-previous-handoff.md',
    '`activeRun`',
    'DownloadState.receiving',
    'previous priority继续为780',
)
require(
    'docs/audits/dev184-current-previous-receiving-state-root-cause-audit.md',
    '3.004',
    '至少有7组',
)
require(
    'docs/audits/dev184-validation-results.md',
    'dev.157–dev.184',
    '没有 Flutter/Dart SDK',
)
require('tool/check.sh', 'test_dev184_receiving_state_detach_current_previous_handoff.py')

pubspec = read('apps/app/pubspec.yaml')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.MULTILINE)
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.MULTILINE,
)
if version is None or int(version.group(1)) < 184:
    raise SystemExit('App build is below dev.184')
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode does not match App build')

print('dev.184 receiving-state detach / current-previous handoff: OK')
