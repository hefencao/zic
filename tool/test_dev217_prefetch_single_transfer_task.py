#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
test = read('packages/sessions/test/download_transfer_owner_test.dart')
spec = read('docs/SPEC.md')
architecture = read('docs/ARCHITECTURE.md')

for token in (
    'if (net.priorityOf(existingTaskKey) != null) {',
    '_migrateDownloadPriority(',
    'return;',
    "if (_networkTaskKeys[id] == existingTaskKey) {",
    '_networkTaskKeys.remove(id);',
    'session.activeRun ||',
    'session.hasWriter ||',
    'if (_networkTaskKeys[id] != taskKey) return;',
):
    require(owner, token, 'stable physical task identity')

# Ensure the critical branch returns before a new task key can be allocated.
branch = owner.split('final existingTaskKey = _networkTaskKeys[id];', 1)[1]
branch = branch.split("final taskKey = 'transfer:${++_taskSequence}:${id.key}';", 1)[0]
priority_branch = branch.split('if (net.priorityOf(existingTaskKey) != null) {', 1)[1]
priority_branch = priority_branch.split('// Defensive stale-key recovery', 1)[0]
require(priority_branch, 'return;', 'existing queued/active task early return')

for token in (
    'queued priority revisions keep one physical transfer task identity',
    'expect(owner.taskKeyFor(id), taskKey);',
    'expect(net.queued, 1);',
    'expect(net.priorityOf(taskKey!), 1000);',
    'expect(transport.opens, 1);',
):
    require(test, token, 'queued revision regression test')

require(spec, 'MUST只更新该task priority并保持task key稳定', 'stable task specification')
require(architecture, 'policy revision只能原位迁移priority', 'stable task architecture')

for rel in (
    'docs/archive/adr/0198-stable-physical-task-identity-across-demand-revisions.md',
    'docs/archive/audits/dev217-prefetch-scheduler-single-task-root-cause-audit.md',
    'docs/archive/audits/dev217-validation-results.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.217 governance file missing: {rel}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android_match = re.search(r'^versionCode=(\d+)$', props, re.MULTILINE)
if version_match is None or int(version_match.group(1)) < 217:
    raise SystemExit('dev.217 app version regression')
if android_match is None or int(android_match.group(1)) < 217:
    raise SystemExit('dev.217 Android version regression')

print('dev.217 prefetch single-transfer task closure: OK')
