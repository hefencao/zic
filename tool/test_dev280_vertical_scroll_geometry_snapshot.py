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
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 280, 'dev.280 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 280, 'dev.280 Android version missing')

reader = text('packages/reader/lib/src/reader_view.dart')
for marker in (
    'late Map<String, double> _verticalLayoutRatios;',
    'Map<String, double>? _pendingVerticalLayoutRatios;',
    'bool get _verticalScrollActive',
    '_pendingVerticalLayoutRatios = widget.pageAspectRatios;',
    'final effectiveRatios = ratios ?? _verticalLayoutRatios;',
    'void _schedulePendingVerticalRatioCommit()',
    '_preserveVerticalAnchor(\n        oldRatios: _verticalLayoutRatios,',
    '_verticalLayoutRatios = pending;',
    '_schedulePendingVerticalRatioCommit();',
    'ScrollEnd and isScrollingNotifier can settle on adjacent frames.',
):
    req(marker in reader, f'vertical geometry snapshot owner missing: {marker}')

# Async ratio changes may preserve/restore an anchor only at the idle commit
# boundary; didUpdateWidget must not directly anchor every measured map update.
ratio_branch = reader[reader.index('if (ratiosChanged) {'):reader.index('\n  @override\n  void dispose()', reader.index('if (ratiosChanged) {'))]
req('_pendingVerticalLayoutRatios = widget.pageAspectRatios;' in ratio_branch,
    'active-scroll ratio updates are not deferred')
req('_verticalLayoutRatios = widget.pageAspectRatios;' in ratio_branch,
    'idle/non-vertical ratio adoption missing')
req('oldWidget.pageAspectRatios != widget.pageAspectRatios' not in reader,
    'legacy value-equality ratio trigger unexpectedly restored')

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical measured ratios stay frozen until active scrolling is idle',
    'async measured geometry must not mutate sliver extents mid-scroll',
    'the latest measured geometry must commit once scrolling is idle',
)

for path in (
    'docs/adr/0259-scroll-stable-vertical-geometry-snapshot.md',
    'docs/audits/dev280-vertical-scroll-geometry-jitter-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.280 governance file: {path}')

require('docs/ARCHITECTURE.md', 'scroll-stable ratio snapshot', 'top-pixel anchor')
require('docs/SPEC.md', 'scroll-stable geometry snapshot', 'latest-wins')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.280', 'vertical geometry snapshot')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.280', 'scroll-stable geometry')
require('docs/NEXT_CHAT_HANDOFF.md', 'dev.280', '纵向滑动抖动', 'scroll-stable')
require('CHANGELOG.md', '0.31.0-dev.280', '纵向滚动稳定 geometry snapshot')

# This fix is presentation-only: frozen resource-policy constants must remain.
require('docs/NEXT_CHAT_HANDOFF.md', 'previous3/next7', 'normal5+current reserved1')

print('PASS: dev.280 scroll-stable vertical geometry snapshot')
