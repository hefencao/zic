#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.322 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.322 forbidden {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 322:
    raise SystemExit('dev.322+ version mismatch')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.322 Android version mismatch')

controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
regression = read('packages/pipeline/test/browsing_direction_policy_test.dart')
analyzer = read('tool/analyze_direction_flip_120hz_jank.py')

for token in (
    'final entry = missingDesired.first;',
    'var missingDesiredStart = 0;',
    'missingDesiredStart = 1;',
    'index = missingDesiredStart',
    'downloadBridgeDesiredAdvanced',
):
    require(controller, token, 'non-mutating bridge advance')
forbid(controller, 'missingDesired.removeAt(', 'fixed-length list mutation')

for token in (
    'active download bridge advances speculative identity without mutating fixed list',
    'returnsNormally',
    "event.payload['downloadBridgeDesiredAdvanced'] == 1",
    'expect(plan.downloads, contains(id.download));',
):
    require(regression, token, 'direct PipelineController regression')

for token in (
    'fixed_list_failures',
    'invalid-bridge-run-fixed-length-mutation-failure',
):
    require(analyzer, token, 'fail-closed analyzer')

for rel in (
    'docs/audits/dev322-active-download-bridge-fixed-list-repair-audit.md',
    'docs/adr/0300-active-download-window-bridge-boundary.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.322 missing artifact: {rel}')

trace = Path('/mnt/data/zic-debug-trace-2026-08-20T02-50-22.jsonl')
if trace.is_file():
    out = subprocess.check_output(
        ['python3', str(ROOT / 'tool/analyze_direction_flip_120hz_jank.py'), str(trace)],
        text=True,
    )
    for token in (
        'task_failed=6463',
        'fixed_list_failures=6463',
        'verdict=invalid-bridge-run-fixed-length-mutation-failure',
    ):
        require(out, token, 'dev.321 invalid-run baseline')

print('dev.322 active download bridge fixed-list repair: OK')
