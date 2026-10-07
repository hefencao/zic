#!/usr/bin/env python3
"""Guard dev.283 vertical visible-target authority."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def req(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(f'FAIL: {message}')

def require(path: str, *markers: str) -> None:
    value = text(path)
    missing = [marker for marker in markers if marker not in value]
    req(not missing, f'{path} missing dev.283 contract: {missing}')

pubspec = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pubspec, re.M)
req(m is not None and int(m.group(1)) >= 283, 'dev.283 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 283, 'dev.283 Android version missing')

reader = text('packages/reader/lib/src/reader_view.dart')
vertical_call = reader[reader.index('  void _emitFromVerticalMetrics('):reader.index('  Coverage? _verticalTargetCoverage(')]
req('inferTargetFromLogicalPosition: false,' in vertical_call,
    'vertical observation still permits PageView logical-position target inference')
emit = reader[reader.index('  void _emitObservation('):reader.index('\n}\n\nfinal class _ReaderFrameTimingTraceContext')]
for marker in (
    'bool inferTargetFromLogicalPosition = true,',
    'targetCoverage == null &&',
    'inferTargetFromLogicalPosition &&',
    'distance > 0.001',
):
    req(marker in emit, f'generic PageView target contract missing: {marker}')
req('targetIndex = logicalPosition > boundedStable' in emit,
    'horizontal/PageView target inference was removed instead of scoped')

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical previous drag does not invent a hidden higher-index target',
    'observation.visibleCoverages.length == 1',
    'observation.targetCoverage == null',
)
req((ROOT / 'docs/archive/adr/0262-vertical-visible-target-authority.md').is_file(),
    'missing dev.283 governance file: docs/archive/adr/0262-vertical-visible-target-authority.md')
require(
    'docs/archive/audits/dev283-vertical-target-directionality-audit.md',
    'visibleIndexes',
    'target=current+1',
)
require('docs/ARCHITECTURE.md', 'targetCoverage', 'page-local fraction', '真实 viewport')
require('docs/SPEC.md', 'targetCoverage', 'MUST 为 null', 'floor/ceil')
require('CHANGELOG.md', '0.31.0-dev.283', 'Vertical visible-target authority')

# Recent fixes remain present; dev.283 is an observation semantic correction,
# not a rollback of geometry or resident texture ownership.
for marker in (
    'inferTargetFromLogicalPosition: false,',
    '_ReaderVerticalScrollPhysics',
    '_pendingVerticalGeometryCorrection',
):
    req(marker in reader, f'dev.280/281 vertical geometry contract regressed: {marker}')
require(
    'packages/texture_bridge/lib/src/android_texture_presenter.dart',
    'residentKey',
    'residentReuse',
)
print('PASS: dev.283 vertical visible-target authority')
