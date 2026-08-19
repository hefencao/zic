#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.309 missing {label}: {token}')

adapter = read('packages/reader_runtime/lib/src/flutter_reader_touch_resampling.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
view = read('packages/reader/lib/src/reader_view.dart')
reader_prod = ''.join(
    path.read_text(encoding='utf-8')
    for path in (ROOT / 'packages/reader/lib').rglob('*.dart')
)
test = read('packages/reader_runtime/test/flutter_reader_touch_resampling_test.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')

for token in (
    "import 'package:flutter/gestures.dart';",
    'final class FlutterReaderTouchResamplingLease',
    'static int _leases = 0;',
    'static bool? _restoreEnabled;',
    'binding.resamplingEnabled = true;',
    'GestureBinding.instance.resamplingEnabled = restoreEnabled;',
):
    require(adapter, token, 'scoped Flutter touch-resampling owner')
if 'samplingOffset' in adapter:
    raise SystemExit('dev.309 must not tune GestureBinding.samplingOffset')
if 'GestureBinding' in reader_prod or 'resamplingEnabled' in reader_prod:
    raise SystemExit('dev.309 leaked Flutter input binding ownership into reader package')

for token in (
    'FlutterReaderTouchResamplingLease? _touchResamplingLease;',
    'void _syncTouchResampling()',
    '_touchResamplingLease ??= FlutterReaderTouchResampling.acquire();',
    '_touchResamplingLease?.release();',
    '_reader = created;\n    _syncTouchResampling();',
    '_reader?.setDirection(candidate.direction);\n    _syncTouchResampling();',
    '_reader?.setDirection(_resolveInitialDirection(_matchingInitialProgress()));\n    _syncTouchResampling();',
):
    require(runtime, token, 'ReaderRuntime lease lifecycle')

for token in (
    'final dragDriven = notification.dragDetails != null;',
    'dragDriven: dragDriven,',
    "'dragDriven': dragDriven,",
    '? Interaction.dragging\n              : Interaction.scrolling;',
):
    require(view, token, 'drag-vs-ballistic cadence observation')

for token in (
    'vertical Reader lease enables and restores touch resampling',
    'nested Reader leases restore only after the final release',
    'pre-existing resampling state is preserved after release',
):
    require(test, token, 'touch-resampling regression')

for forbidden in (
    'samplingOffset =',
    'PointerMoveEvent(',
    'AnimationController(',
    'Ticker(',
    'scheduleFrame()',
):
    if forbidden in adapter:
        raise SystemExit(f'dev.309 introduced forbidden custom input/frame behavior: {forbidden}')

for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0288-vertical-reader-touch-resampling-boundary.md',
    'docs/audits/dev309-scroll-cadence-touch-resampling-audit.md',
))
for token in (
    '49', '31.775ms', '36.668ms', '75.923ms',
    'resamplingEnabled', 'dragDriven', 'samplingOffset',
    '963ms', '764ms',
):
    require(all_docs, token, 'governed dev.309 evidence/boundary')

for path, limit in (
    ('docs/ARCHITECTURE.md', 420),
    ('docs/IMPLEMENTATION_PLAN.md', 180),
    ('docs/IMPLEMENTATION_STATUS.md', 220),
    ('docs/NEXT_CHAT_HANDOFF.md', 80),
):
    lines = read(path).splitlines()
    if len(lines) > limit:
        raise SystemExit(f'dev.309 documentation budget exceeded: {path} {len(lines)}>{limit}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 309:
    raise SystemExit('dev.309 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.309 Android version mismatch')

print('dev.309 vertical touch-resampling / scroll-cadence boundary: OK')
