#!/usr/bin/env python3
"""Guard dev.286 live aspect projection over frozen vertical layout."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(f'FAIL: {message}')


def require(path: str, *markers: str) -> None:
    body = text(path)
    missing = [marker for marker in markers if marker not in body]
    req(not missing, f'{path} missing dev.286 contract: {missing}')

pubspec = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pubspec, re.M)
req(m is not None and int(m.group(1)) >= 286, 'dev.286 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 286, 'dev.286 Android version missing')

geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
for marker in (
    'double presentationExtentAt(',
    '_computeExtent(index, presentationRatios)',
    '_computeExtent(index, ratios)',
):
    req(marker in geometry, f'live presentation geometry missing: {marker}')

reader = text('packages/reader/lib/src/reader_view.dart')
for marker in (
    'final layoutExtent = geometry.extentAt(pageIndex);',
    'final presentationExtent = geometry.presentationExtentAt(',
    'widget.pageAspectRatios,',
    "'reader-vertical-presentation:$pageIndex'",
    'final presentation = OverflowBox(',
    'alignment: Alignment.topCenter,',
    'height: layoutExtent,',
    'presentationDiffers',
):
    req(marker in reader, f'vertical live-aspect presentation missing: {marker}')
req('return geometry.extentAt(pageIndex);' in reader,
    'itemExtentBuilder no longer uses frozen layout geometry')
req('_pendingVerticalLayoutRatios = widget.pageAspectRatios;' in reader,
    'dev.280 active-scroll ratio deferral was removed')

# The generic media component must keep the existing exact-box contract; the
# transient stale-layout fix belongs to Reader presentation geometry.
require(
    'packages/local_media_ui/lib/src/local_image_player.dart',
    'if (fit == BoxFit.fitWidth) {',
    'ReaderVerticalGeometry already owns the exact',
    'child: builder(BoxFit.fill)',
)

require(
    'packages/reader/test/reader_navigation_test.dart',
    'vertical measured ratios stay frozen until active scrolling is idle',
    'newly measured media must use its live aspect ratio inside the frozen sliver box instead of stretching until idle',
)
require(
    'packages/reader/test/vertical_reader_geometry_test.dart',
    'live presentation ratio does not mutate the frozen layout snapshot',
    'live presentation ratios must not mutate sliver layout extent',
)

for path in (
    'docs/adr/0265-live-aspect-projection-over-frozen-vertical-layout.md',
    'docs/audits/dev286-vertical-live-aspect-projection-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.286 governance file: {path}')

require('docs/ARCHITECTURE.md', 'visual presentation extent', 'top-align')
require('docs/SPEC.md', 'MUST NOT被拉伸到旧fallback/旧extent', 'top-align')
# dev.284 production guard was superseded in dev.285; stable spec must not
# continue to require it.
spec = text('docs/SPEC.md')
req('mount-travel guard MUST按页面位移' not in spec,
    'superseded dev.284 mount-travel guard remains normative in SPEC')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.286', '113%', 'presentationExtentAt')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.286', 'live-aspect projection')
require('docs/NEXT_CHAT_HANDOFF.md', 'dev.286', 'presentationExtentAt(latestRatios)')
require('CHANGELOG.md', '0.31.0-dev.286', 'Live aspect projection over frozen vertical layout')

check = text('tool/check.sh')
req('test_dev286_live_aspect_projection.py' in check,
    'dev.286 gate not wired into tool/check.sh')

print('PASS: dev.286 live aspect projection over frozen vertical layout')
