#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, token: str, label: str) -> None:
    if token not in body:
        raise SystemExit(f'dev.325 missing {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
app_version = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android_version = re.search(r'^versionCode=(\d+)$', props, re.M)
if (app_version is None or android_version is None or
        app_version.group(1) != android_version.group(1) or
        int(app_version.group(1)) < 325):
    raise SystemExit('dev.325 compatibility boundary version mismatch')

coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
session = read('packages/sessions/lib/src/upload_session.dart')
registry = read('packages/sessions/lib/src/upload_registry.dart')
regression = read('packages/sessions/test/live_coordinator_test.dart')
session_test = read('packages/sessions/test/upload_session_test.dart')
analyzer = read('tool/analyze_current_role_boundary_jank.py')

for token in (
    '!pendingSourceWake',
    '!_decodeNeedsFill(',
    'decode.cancelQueued(entry.key.key);',
    'uploadRegistry.reusePreparedStaticForDemand(',
    'upload.cancelQueued(entry.key.key);',
):
    require(coordinator, token, 'satisfied-static coordinator fast path')

for token in (
    'bool reusePreparedStaticForDemand({',
    '_pendingPrepares != 0',
    '!hasRetainableStaticOutput',
    '(holder != null && !holder.isEmpty)',
    'decodeSnapshot.failure != null',
    '_latestDemandRole = demand.role;',
):
    require(session, token, 'strict UploadSession static adoption guard')

require(registry, 'bool reusePreparedStaticForDemand(', 'UploadRegistry projection')
for token in (
    'static revisit must not enqueue a no-op upload lane task',
    'static revisit must not enqueue a no-op decode fill',
):
    require(regression, token, 'LiveCoordinator revisit regression')
require(session_test, 'static-role-migration', 'direct UploadSession regression')
for token in (
    'current-role-promotion-control-plane-spike',
    'current_boundary_reconcile=',
    'current_boundary_lane_starts=',
):
    require(analyzer, token, 'current boundary analyzer')

for rel in (
    'docs/archive/adr/0302-current-role-satisfied-static-scheduler-boundary.md',
    'docs/archive/audits/dev325-current-role-satisfied-static-scheduler-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.325 missing artifact: {rel}')

trace = Path('/mnt/data/zic-debug-trace-2026-08-20T05-33-02.jsonl')
if trace.is_file():
    out = subprocess.check_output(
        ['python3', str(ROOT / 'tool/analyze_current_role_boundary_jank.py'), str(trace)],
        text=True,
    )
    for token in (
        'task_failed=0',
        'current_promotions=36',
        'current_boundary_reconciles=36',
        'median_us=3895',
        'ge_3000=32/36',
        'other_reconciles=80',
        'current_median=0.507',
        'upload_median=2',
        'verdict=current-role-promotion-control-plane-spike',
    ):
        require(out, token, '05:33 current-role baseline')

print('dev.325 current-role satisfied-static scheduler boundary: OK')
