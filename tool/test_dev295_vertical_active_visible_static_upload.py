#!/usr/bin/env python3
"""Ownership gate for dev.295 vertical active hidden-static upload deferral."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.295 tokens: {missing}')

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded dev.295 tokens: {found}')

import re
pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
dev_match = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
if dev_match is None or int(dev_match.group(1)) < 295:
    raise SystemExit('FAIL: dev.295+ app version missing')
if android_match is None or int(android_match.group(1)) < 295:
    raise SystemExit('FAIL: dev.295+ Android version missing')
current_dev = int(dev_match.group(1))
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'final deferHiddenVerticalStaticUpload =',
    'observation.direction == ReadingDirection.vertical',
    'staticWarm &&',
    '!primaryUpload',
    '!visibleStatic',
    '_verticalPresentationActive(observation.interaction)',
    'if ((primaryUpload || staticWarm) && !deferHiddenVerticalStaticUpload)',
)
forbid('packages/pipeline/lib/src/heuristic_policy.dart', 'final deferVerticalNext2Upload =')
require(
    'packages/pipeline/test/pipeline_test.dart',
    "'a truly visible immediate next page still uploads'",
    "'hidden immediate next keeps its decoded warm frame'",
    "'hidden immediate next must not blit a static texture during active vertical scrolling'",
    'final idlePlan = policy.createPlan(',
)
require(
    'packages/reader/lib/src/reader_view.dart',
    'final scheduledPixels = metrics.pixels;',
    'final observedPixels = position?.pixels ?? scheduledPixels;',
    "'scheduledScrollPixels': scheduledPixels",
    'globalOrigin.dy + observedPixels - expected.start',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'docs/adr/0274-vertical-active-visible-static-upload-boundary.md',
    '24.4ms',
    'hidden speculative static page',
    'DecodeDemand继续按既有decode 2/1',
)
require(
    'docs/audits/dev295-hidden-static-upload-jitter-audit.md',
    '333条`pageLayoutSnapshot`',
    '24.416ms',
    '14.809ms',
    '`deferHiddenVerticalStaticUpload`',
)
if current_dev == 295:
    require('docs/NEXT_CHAT_HANDOFF.md', '# dev.295 后续交接', 'hidden speculative static')
else:
    require(
        'docs/NEXT_CHAT_HANDOFF.md',
        f'# dev.{current_dev} 后续交接',
        'dev.295目标已正面闭合',
        'staticWarmUploads=0',
    )
forbid('packages/reader/lib/src/reader_view.dart', 'presentationExtentAt(')
print('dev.295 vertical active visible-static upload boundary: OK')
