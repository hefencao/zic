#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.309 missing {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 309:
    raise SystemExit('dev.309 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.309 Android version mismatch')

runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
view = read('packages/reader/lib/src/reader_view.dart')
reader_prod = ''.join(
    path.read_text(encoding='utf-8')
    for path in (ROOT / 'packages/reader/lib').rglob('*.dart')
)
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')

for token in (
    'final dragDriven = notification.dragDetails != null;',
    'dragDriven: dragDriven,',
    "'dragDriven': dragDriven,",
    '? Interaction.dragging\n              : Interaction.scrolling;',
):
    require(view, token, 'drag-vs-ballistic cadence observation')

for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')

if 'GestureBinding' in reader_prod or 'resamplingEnabled' in reader_prod:
    raise SystemExit('dev.309 leaked Flutter input binding ownership into reader package')

adapter_path = ROOT / 'packages/reader_runtime/lib/src/flutter_reader_touch_resampling.dart'
test_path = ROOT / 'packages/reader_runtime/test/flutter_reader_touch_resampling_test.dart'
if version < 310:
    if not adapter_path.exists() or not test_path.exists():
        raise SystemExit('dev.309 touch-resampling historical implementation missing')
    adapter = adapter_path.read_text(encoding='utf-8')
    test = test_path.read_text(encoding='utf-8')
    for token in (
        "import 'package:flutter/gestures.dart';",
        'final class FlutterReaderTouchResamplingLease',
        'static int _leases = 0;',
        'static bool? _restoreEnabled;',
        'binding.resamplingEnabled = true;',
        'GestureBinding.instance.resamplingEnabled = restoreEnabled;',
    ):
        require(adapter, token, 'scoped Flutter touch-resampling owner')
    for token in (
        'FlutterReaderTouchResamplingLease? _touchResamplingLease;',
        'void _syncTouchResampling()',
        '_touchResamplingLease ??= FlutterReaderTouchResampling.acquire();',
        '_touchResamplingLease?.release();',
    ):
        require(runtime, token, 'ReaderRuntime lease lifecycle')
    for token in (
        'vertical Reader lease enables and restores touch resampling',
        'nested Reader leases restore only after the final release',
        'pre-existing resampling state is preserved after release',
    ):
        require(test, token, 'touch-resampling regression')
    if 'samplingOffset' in adapter:
        raise SystemExit('dev.309 must not tune GestureBinding.samplingOffset')
else:
    if not adapter_path.exists() or not test_path.exists():
        raise SystemExit('ADR 0325 scoped touch-resampling owner missing')
    adapter = adapter_path.read_text(encoding='utf-8')
    test = test_path.read_text(encoding='utf-8')
    for token in (
        "import 'package:flutter/gestures.dart';",
        'final class FlutterReaderTouchResamplingLease',
        'static int _leases = 0;',
        'static bool? _restoreEnabled;',
        'binding.resamplingEnabled = true;',
        'GestureBinding.instance.resamplingEnabled = restoreEnabled;',
    ):
        require(adapter, token, 'ADR 0325 scoped Flutter touch-resampling owner')
    for token in (
        'FlutterReaderTouchResamplingLease? _touchResamplingLease;',
        'void _syncTouchResampling()',
        '_touchResamplingLease ??= FlutterReaderTouchResampling.acquire();',
        '_touchResamplingLease?.release();',
    ):
        require(runtime, token, 'ADR 0325 ReaderRuntime lease lifecycle')
    for token in (
        'vertical Reader lease enables and restores touch resampling',
        'nested Reader leases restore only after final release',
        'pre-existing resampling state is preserved after release',
    ):
        require(test, token, 'ADR 0325 touch-resampling regression')
    if 'samplingOffset' in adapter:
        raise SystemExit('ADR 0325 must not tune GestureBinding.samplingOffset')
    adr = read('docs/adr/0288-vertical-reader-touch-resampling-boundary.md')
    require(adr, '## Status\n\nSuperseded', 'canonical ADR status')
    require(adr, 'ADR 0325', 'dev.309/310 scoped supersession')
    for token in ('20/22', '`dragDriven=false`', 'post-lift holes'):
        require(adr, token, 'retained dev.310 ballistic falsification record')

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
    'dragDriven', 'samplingOffset', '963ms', '764ms',
):
    require(all_docs, token, 'governed dev.309 evidence/boundary')

for path, limit in (
    ('docs/IMPLEMENTATION_PLAN.md', 180),
    ('docs/IMPLEMENTATION_STATUS.md', 220),
    ('docs/NEXT_CHAT_HANDOFF.md', 80),
):
    lines = read(path).splitlines()
    if len(lines) > limit:
        raise SystemExit(f'dev.309 documentation budget exceeded: {path} {len(lines)}>{limit}')

print('dev.309 vertical touch-resampling / scroll-cadence boundary: OK')
