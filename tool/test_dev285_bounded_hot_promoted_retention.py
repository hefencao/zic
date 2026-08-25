#!/usr/bin/env python3
"""Guard dev.285 bounded hot promoted physical-session retention."""
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
    req(not missing, f'{path} missing dev.285 contract: {missing}')

pubspec = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pubspec, re.M)
req(m is not None and int(m.group(1)) >= 285, 'dev.285 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 285, 'dev.285 Android version missing')

retention = text('packages/downloads/lib/src/physical_transfer_retention.dart')
for marker in (
    'this.maxIdlePromotedSessions = 8',
    'final int maxIdlePromotedSessions;',
    'await _trimIdlePromoted();',
    'Future<void> _trimIdlePromoted() async {',
    'if (candidates.length <= maxIdlePromotedSessions) return;',
    "reason: 'hot-promoted-retention-pressure'",
    "'maxIdlePromotedSessions': maxIdlePromotedSessions",
    "'retainedIdlePromotedSessions': idlePromoted.length",
    'await handoff.settleAutomatic(session)',
    'await owner.retireIdlePhysical(session.id)',
):
    req(marker in retention, f'bounded promoted retention missing: {marker}')
req('_retireIdlePromoted' not in retention,
    'immediate all-promoted retirement helper remains')

runtime = text('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
for marker in (
    'this.maxIdlePromotedSessions = 8',
    'final int maxIdlePromotedSessions;',
    'maxIdlePromotedSessions: maxIdlePromotedSessions',
    'this.maxIdlePartialSessions = 32',
    'this.maxIdlePartialBytes = 256 * 1024 * 1024',
):
    req(marker in runtime, f'composition runtime retention budget missing: {marker}')

# Device-falsified dev.284 UI keepAlive behavior must actually be absent.
reader = text('packages/reader/lib/src/reader_view.dart')
geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
for forbidden in (
    '_compositionMountedAtCurrentIndex',
    'compositionGuardActive: _compositionGuardActive',
    'readerVerticalCompositionMountTravelGuardPages',
):
    req(forbidden not in reader + geometry, f'dev.284 rollback incomplete: {forbidden}')
version = int(m.group(1))
if version < 307:
    req('(widget.index - controller.currentIndex).abs() <= 7' in reader,
        'nominal vertical keepAlive radius not restored')
else:
    req('(widget.index - widget.keepAliveCenter.value).abs() <= 7' in reader,
        'dev.307 must preserve the same bounded current±7 keepAlive radius')
    req('late final ValueNotifier<int> _verticalKeepAliveCenter;' in reader,
        'dev.307 bounded keepAlive center missing')

require(
    'packages/downloads/test/physical_transfer_retention_test.dart',
    'promoted idle physical session stays hot inside bounded retention',
    'promoted pressure retires only the oldest durable hot session',
    'maxIdlePromotedSessions: 1',
    'maxIdlePromotedSessions: 0',
)

req((ROOT / 'docs/adr/0264-bounded-hot-promoted-physical-retention.md').is_file(),
    'missing dev.285 governance file: docs/adr/0264-bounded-hot-promoted-physical-retention.md')
require(
    'docs/audits/dev285-fixed-region-promoted-physical-retention-audit.md',
    'dev.285',
    'hot-promoted-retention-pressure',
)
require('docs/ARCHITECTURE.md', '8-session LRU hot tail', 'ordinary handoff')
require('docs/SPEC.md', '默认最多8个', 'promoted hot budget')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.285', '84次', 'session-copy')
require('CHANGELOG.md', '0.31.0-dev.285', 'Bounded hot promoted physical retention')

check = text('tool/check.sh')
req('test_dev285_bounded_hot_promoted_retention.py' in check,
    'dev.285 gate not wired into tool/check.sh')

print('PASS: dev.285 bounded hot promoted physical retention')
