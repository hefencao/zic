#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

# dev.316 keeps this experiment only as historical evidence; production behavior is rolled back.
_version_text = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
_version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', _version_text, re.M)
if _version_match is not None and int(_version_match.group(1)) >= 316:
    for _rel in (
        'docs/adr/0293-fixed-position-hidden-static-upload-boundary.md',
        'docs/audits/dev314-fixed-position-hidden-static-upload-audit.md',
    ):
        if not (ROOT / _rel).is_file(): raise SystemExit(f'missing historical dev.314 artifact: {_rel}')
    print('dev.314 fixed-position hidden static upload boundary: FALSIFIED and rolled back')
    raise SystemExit(0)



def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.314 missing {label}: {token}')


policy = read('packages/pipeline/lib/src/heuristic_policy.dart')
test = read('packages/pipeline/test/pipeline_test.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
analyzer = read('tool/analyze_vertical_fixed_position_jank.py')

for token in (
    'final deferHiddenVerticalStaticUpload =',
    'observation.direction == ReadingDirection.vertical',
    '!primaryUpload',
    '!visibleStatic',
    '_verticalPresentationActive(observation.interaction)',
    'retainOutput: visibleStatic || localStaticReady',
):
    require(policy, token, 'active hidden-static boundary')
if '!localStaticReady &&' in policy:
    raise SystemExit('dev.314 restored active hidden local-static upload exception')

for token in (
    'local static evidence must not start hidden platform blits during active vertical scrolling',
    'classification must not start a hidden texture blit during active scroll',
    'idle may pre-present an authoritative local static neighbor',
    'active vertical scrolling must keep next2 decode warm',
):
    require(test, token, 'policy regression')

for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

for token in (
    'scroll_outliers_by_current_index',
    'paired_platform_upload_roles',
    'blitMicros',
    'next2',
):
    require(analyzer, token, 'fixed-position trace analyzer')

for rel in (
    'docs/adr/0293-fixed-position-hidden-static-upload-boundary.md',
    'docs/audits/dev314-fixed-position-hidden-static-upload-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.314 missing governance artifact: {rel}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0287-local-static-prepresentation-and-reverse-geometry-preparation.md',
    'docs/adr/0293-fixed-position-hidden-static-upload-boundary.md',
    'docs/audits/dev314-fixed-position-hidden-static-upload-audit.md',
))
for token in (
    '148', 'index20=42', '16.163ms', '40.658911', '40.679514',
    '16/19', 'vibevenera-master.zip', '180ms', 'Superseded',
    'single-variable',
):
    require(docs, token, 'governed fixed-position evidence')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 314:
    raise SystemExit('dev.314 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.314 Android version mismatch')

# The intervention must not mutate any of the already-falsified scroll/frame paths.
product = policy + read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
for forbidden in (
    'GestureBinding.resamplingEnabled',
    'samplingOffset',
    'setRequestedFrameRate(',
    'preferredRefreshRate =',
):
    if forbidden in product:
        raise SystemExit(f'dev.314 leaked unrelated behavior: {forbidden}')

print('dev.314 fixed-position hidden static upload boundary: OK')
