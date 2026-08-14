#!/usr/bin/env python3
"""Guard dev.284 vertical composition cache-boundary retention."""
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
    req(not missing, f'{path} missing dev.284 contract: {missing}')

pubspec = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pubspec, re.M)
req(m is not None and int(m.group(1)) >= 284, 'dev.284 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 284, 'dev.284 Android version missing')

geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
for marker in (
    'readerVerticalCompositionKeepAliveRadius = 7',
    'readerVerticalCompositionMountTravelGuardPages = 2',
    'bool readerVerticalCompositionGuardActive({',
    'bool readerVerticalCompositionShouldKeepAlive({',
    '(pageIndex - currentIndex).abs() <=',
    'readerVerticalCompositionGuardActive(',
):
    req(marker in geometry, f'vertical composition guard missing: {marker}')

reader = text('packages/reader/lib/src/reader_view.dart')
shell = reader[reader.index('final class _ReaderPageShellState'):reader.index('final class _ReaderPageHost')]
for marker in (
    '_compositionMountedAtCurrentIndex',
    '_compositionGuardActiveFor',
    'readerVerticalCompositionShouldKeepAlive(',
    '(widget.index - controller.currentIndex).abs() <= 7',
    'compositionGuardActive: _compositionGuardActive',
):
    req(marker in shell, f'Reader composition retention missing: {marker}')
retention = shell[shell.index('  bool _compositionGuardActiveFor'):shell.index('  void _readControllerState()')]
req('Timer(' not in retention and 'Future.delayed(' not in retention,
    'composition retention regressed to a timer/grace owner')

host = reader[reader.index('final class _ReaderPageHost'):]
for marker in (
    'required this.compositionGuardActive',
    'final bool compositionGuardActive;',
    'AutomaticKeepAliveClientMixin<_ReaderPageHost>',
    'bool get wantKeepAlive => widget.keepAlive',
    "'compositionGuardActive': widget.compositionGuardActive",
):
    req(marker in host, f'page-host trace/keepalive contract missing: {marker}')

# Keep the existing pixel cache policy. dev.284 adds composition hysteresis instead
# of moving the sliver cache edge or changing media-resource windows.
for marker in (
    '_verticalCacheScreens = 2',
    '_verticalCacheScreens >= 7',
    '_viewport.height * _verticalCacheScreens',
    'cacheExtent: cacheExtent',
):
    req(marker in reader, f'vertical cache policy changed unexpectedly: {marker}')

require(
    'packages/reader/test/vertical_reader_geometry_test.dart',
    'composition mount guard absorbs local cache-boundary reversals',
    'nominal vertical composition window remains seven pages',
    'mountedAtCurrentIndex: 10',
)
for path in (
    'docs/adr/0263-vertical-composition-boundary-retention.md',
    'docs/audits/dev284-vertical-composition-cache-boundary-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.284 governance file: {path}')
require('docs/ARCHITECTURE.md', 'composition guard', 'current±7', 'mount point超过2页')
require('docs/SPEC.md', 'composition retention', 'current±7', 'mount current', 'timer/grace')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.284', 'page18', 'compositionGuardActive')
require('docs/IMPLEMENTATION_PLAN.md', 'dev.284', 'cache-edge page host', 'Sliver layout/frame timing')
require('docs/NEXT_CHAT_HANDOFF.md', 'dev.284', 'compositionGuardActive', 'cache-edge')
require('CHANGELOG.md', '0.31.0-dev.284', 'composition cache-boundary retention')

# dev.283 target authority and dev.282 resident reuse are explicitly retained;
# this fix must stay in UI composition ownership.
require('packages/reader/lib/src/reader_view.dart', 'inferTargetFromLogicalPosition: false,')
require('packages/texture_bridge/lib/src/android_texture_presenter.dart', 'residentKey', 'residentReuse')

print('PASS: dev.284 vertical composition cache-boundary retention')
