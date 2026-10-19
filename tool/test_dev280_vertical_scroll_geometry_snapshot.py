#!/usr/bin/env python3
"""Guard dev.280 scroll-stable vertical geometry snapshot ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)


def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.280 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 280, 'dev.280 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 280, 'dev.280 Android version missing')

reader = text('packages/reader/lib/src/reader_view.dart')
for marker in (
    'late Map<String, double> _verticalLayoutRatios;',
    'Map<String, double>? _pendingVerticalLayoutRatios;',
    'bool get _verticalScrollActive',
    '_pendingVerticalLayoutRatios =',
    'layoutChanged = _adoptFutureVerticalRatios(latest);',
    'void _adoptPageAspectRatios(',
    'bool _adoptFutureVerticalRatios(',
    'final effectiveRatios = ratios ?? _verticalLayoutRatios;',
    'void _schedulePendingVerticalRatioCommit()',
    '_preserveVerticalAnchor(\n        oldRatios: _verticalLayoutRatios,',
    '_verticalLayoutRatios = pending;',
    '_schedulePendingVerticalRatioCommit();',
    'ScrollEnd and isScrollingNotifier can settle on adjacent frames.',
):
    req(marker in reader, f'vertical geometry snapshot owner missing: {marker}')

# Async ratio changes from either didUpdateWidget or the live listenable must
# converge through one geometry owner. Active-scroll prefix-affecting changes
# stay pending; only future-page-safe facts may be adopted immediately.
ratio_branch = reader[
    reader.index('void _adoptPageAspectRatios('):
    reader.index('bool _adoptFutureVerticalRatios(', reader.index('void _adoptPageAspectRatios('))
]
for marker in (
    '_pendingVerticalLayoutRatios =',
    'layoutChanged = _adoptFutureVerticalRatios(latest);',
    '_verticalLayoutRatios = latest;',
    '_preserveVerticalAnchor(',
):
    req(marker in ratio_branch, f'unified ratio adoption owner missing: {marker}')
update_branch = reader[
    reader.index('if (ratiosChanged) {'):
    reader.index('\n  @override\n  void dispose()', reader.index('if (ratiosChanged) {'))
]
req('_adoptPageAspectRatios(' in update_branch,
    'didUpdateWidget bypasses the unified ratio adoption owner')
req('oldWidget.pageAspectRatios != widget.pageAspectRatios' not in reader,
    'legacy value-equality ratio trigger unexpectedly restored')

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical measured ratios stay frozen until active scrolling is idle',
    'async measured geometry must not mutate sliver extents mid-scroll',
    'the latest measured geometry must commit once scrolling is idle',
    'live vertical ratios rebuild only when ListView geometry changes',
)

for path in (
    'docs/archive/adr/0259-scroll-stable-vertical-geometry-snapshot.md',
    'docs/archive/audits/dev280-vertical-scroll-geometry-jitter-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.280 governance file: {path}')

require('docs/ARCHITECTURE.md', 'scroll-stable layout snapshot', 'top-pixel')
require('docs/SPEC.md', 'viewport prefix', 'latest-wins')
require('docs/IMPLEMENTATION_STATUS.md', 'ratio live feed', 'vertical模式只有extent真实变化', 'anchor/geometry rebuild')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.280', 'scroll-stable geometry')
require('CHANGELOG.md', '0.31.0-dev.280', '纵向滚动稳定 geometry snapshot')

print('PASS: dev.280 scroll-stable vertical geometry snapshot')
