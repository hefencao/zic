#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'vertical drag-resampling missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'vertical drag-resampling forbidden {label}: {token}')

reader = read('packages/reader/lib/src/reader_view.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
adapter = read('packages/reader_runtime/lib/src/flutter_reader_touch_resampling.dart')
test = read('packages/reader_runtime/test/flutter_reader_touch_resampling_test.dart')
main = read('apps/app/lib/main.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
adr = read('docs/adr/0325-vertical-drag-displacement-resampling.md')

for token in ('GestureBinding', 'resamplingEnabled', 'samplingOffset'):
    forbid(reader, token, 'Reader framework-input ownership')
    forbid(main, token, 'app-global resampling mutation')

for token in (
    "import 'package:flutter/gestures.dart';",
    'final class FlutterReaderTouchResamplingLease',
    'static int _leases = 0;',
    'static bool? _restoreEnabled;',
    'binding.resamplingEnabled = true;',
    'GestureBinding.instance.resamplingEnabled = restoreEnabled;',
):
    require(adapter, token, 'scoped framework owner')
forbid(adapter, 'samplingOffset', 'custom sampling offset')

for token in (
    "import 'flutter_reader_touch_resampling.dart';",
    'FlutterReaderTouchResamplingLease? _touchResamplingLease;',
    'void _syncTouchResampling()',
    '_touchResamplingLease ??= FlutterReaderTouchResampling.acquire();',
    '_touchResamplingLease?.release();',
):
    require(runtime, token, 'vertical Reader lease lifecycle')

for token in (
    'vertical Reader lease enables and restores touch resampling',
    'nested Reader leases restore only after final release',
    'pre-existing resampling state is preserved after release',
):
    require(test, token, 'lease regression')

for token in (
    '_verticalSceneMotionDragVelocityStepCount',
    '_verticalSceneMotionDragVelocityStepOutlierCount',
    "'dragVelocityStepMeanRatio'",
    "'maxDragVelocityStepRatio'",
    "'ballisticVelocityStepMeanRatio'",
):
    require(reader, token, 'drag-vs-ballistic displacement diagnostic')

for token in (
    'zic-debug-trace-2026-09-24T12-25-28.jsonl',
    'zic-debug-trace-2026-09-24T12-28-48.jsonl',
    '14/98',
    '255.28%',
    '0/113',
    '0.0171%',
    'post-lift ballistic',
):
    require(adr, token, 'matched A/B evidence')

for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
):
    require(profile, token, 'unchanged Pipeline window')

print('vertical drag displacement resampling boundary: OK')
