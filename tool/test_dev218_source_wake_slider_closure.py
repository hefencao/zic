#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.218 missing {label}: {token}')

live = read('packages/sessions/lib/src/live_coordinator.dart')
slider = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
live_test = read('packages/sessions/test/live_coordinator_test.dart')
ui_test = read('apps/app/test/reader_controls_test.dart')
spec = read('docs/SPEC.md')
architecture = read('docs/ARCHITECTURE.md')

require(live, 'int _availableSourceRevision(DownloadId id)', 'projection revision state lookup')
pubspec = read('apps/app/pubspec.yaml')
version_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
if version_match is None:
    raise SystemExit('dev.218 app version mismatch')
build = int(version_match.group(1))
if build >= 253:
    require(live, '_sourceWatches[id]?.projection.snapshot.revision', 'generation-aware projection revision fallback')
else:
    require(live, 'ingresses?.find(id)?.snapshot.revision', 'projection revision fallback')
require(live, '!_decodeNeedsFill(', 'safe null-refill source consumption')
require(live, 'sourceWake: true,', 'source-wake necessity proof')
require(slider, 'widget.requestedIndex ?? widget.currentIndex', 'slider pending request projection')
require(slider, '_previewIndex ?? widget.requestedIndex ?? widget.currentIndex', 'slider scrub preview preserves pending request projection')
require(live_test, 'gated source revision survives until prefetch is promoted current', 'decode regression test')
require(live_test, 'expect(waiting.state, DecodeState.waitingSource)', 'waiting-source fixture')
require(live_test, 'expect(afterPromotion.depth, greaterThanOrEqualTo(1))', 'promotion recovery assertion')
require(ui_test, 'final gesture = await tester.startGesture(', 'real slider gesture regression')
require(ui_test, 'tester.widget<Slider>(sliderFinder).value, greaterThan(1)', 'slider controlled-value assertion')
require(spec, 'staged refill policy 因 current bootstrap 暂时返回空决策 MUST NOT', 'source revision spec')
require(architecture, 'current-bootstrap 暂时门控邻页不得吞掉其 pending source wake', 'source revision architecture')

for rel in (
    'docs/adr/0199-pending-source-revision-and-reader-slider-request-projection.md',
    'docs/audits/dev218-source-wake-slider-root-cause-audit.md',
    'docs/audits/dev218-validation-results.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.218 governance file missing: {rel}')

props = read('apps/app/android/zic-version.properties')
android_match = re.search(r'^versionCode=(\d+)$', props, re.MULTILINE)
if build < 218:
    raise SystemExit('dev.218 app version mismatch')
if android_match is None or int(android_match.group(1)) < 218:
    raise SystemExit('dev.218 Android version mismatch')

print('dev.218 source-wake slider closure: OK')
