#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.321 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.321 forbidden {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 321:
    raise SystemExit('dev.321+ version mismatch')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.321 Android version mismatch')

controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')

for token in (
    '_bridgeActiveVerticalDownloads(',
    'allowSpeculativeAdvance:',
    'bool immediateMediaRole(PageRole role)',
    'if (immediateMediaRole(entry.value.role)) entry.key.download',
    'if (immediateMediaRole(entry.value.role) ||',
    'entry.value.viewportVisible)',
    'Far one-frame work follows the bridged source',
    'Advance at most one encoded-only speculative identity per committed page',
    'downloadBridgeActive',
    'downloadBridgeLocalMovement',
    'downloadBridgeRetained',
    'downloadBridgeDeferredDesired',
    'downloadBridgeDesiredAdvanced',
    'downloadBridgeSchedulingRetained',
):
    require(controller, token, 'active encoded-download bridge')

require(session, 'Timer.run(() => _drainObservation(generation));', 'dev.317 event-turn seam')
for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
    'maxDownloadDemands: 11',
):
    require(profile, token, 'canonical stable window')

product = controller + session + profile
for token in (
    'Duration(milliseconds: 180)',
    'GestureBinding.resamplingEnabled',
    'samplingOffset =',
    'setRequestedFrameRate(',
):
    forbid(product, token, 'superseded behavior experiment')

for rel in (
    'tool/analyze_direction_flip_120hz_jank.py',
    'docs/archive/adr/0300-active-download-window-bridge-boundary.md',
    'docs/archive/audits/dev321-active-download-window-bridge-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.321 missing artifact: {rel}')

trace = Path('/mnt/data/zic-debug-trace-2026-08-20T01-31-20.jsonl')
if trace.is_file():
    out = subprocess.check_output(
        ['python3', str(ROOT / 'tool/analyze_direction_flip_120hz_jank.py'), str(trace)],
        text=True,
    )
    for token in (
        'active_direction_flips=13',
        'big_5x5=13',
        'added_median=5',
        'removed_median=5',
        'median_us=7455',
        'budget_120hz_us=8333',
        'verdict=active-direction-flip-full-window-churn',
    ):
        require(out, token, 'dev.320 trace baseline')

print('dev.321 active download-window bridge boundary: OK')
