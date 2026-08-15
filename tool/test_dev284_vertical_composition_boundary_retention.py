#!/usr/bin/env python3
"""Guard dev.284 history after dev.285 device-falsified supersession."""
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
    req(not missing, f'{path} missing dev.284 supersession contract: {missing}')

pubspec = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pubspec, re.M)
req(m is not None and int(m.group(1)) >= 284, 'dev.284 app version history missing')

adr = text('docs/adr/0263-vertical-composition-boundary-retention.md')
req('状态：Superseded' in adr, 'dev.284 ADR must be superseded after negative device result')
require(
    'docs/adr/0263-vertical-composition-boundary-retention.md',
    'dev.285 / ADR 0264',
    'production 回滚',
)
require(
    'docs/audits/dev284-vertical-composition-cache-boundary-audit.md',
    'page18',
    'sliver cache边界',
)

# The failed dev.284 production behavior must stay rolled back rather than be
# retained merely to satisfy its historical gate.
geometry = text('packages/reader/lib/src/vertical_reader_geometry.dart')
for forbidden in (
    'readerVerticalCompositionMountTravelGuardPages',
    'readerVerticalCompositionGuardActive',
    'readerVerticalCompositionShouldKeepAlive',
):
    req(forbidden not in geometry, f'superseded dev.284 geometry guard remains: {forbidden}')

reader = text('packages/reader/lib/src/reader_view.dart')
for forbidden in (
    '_compositionMountedAtCurrentIndex',
    '_compositionGuardActiveFor',
    'compositionGuardActive: _compositionGuardActive',
):
    req(forbidden not in reader, f'superseded dev.284 Reader guard remains: {forbidden}')
req('(widget.index - controller.currentIndex).abs() <= 7' in reader,
    'nominal vertical page-host keepAlive contract was not restored')

test_text = text('packages/reader/test/vertical_reader_geometry_test.dart')
req('composition mount guard absorbs local cache-boundary reversals' not in test_text,
    'superseded dev.284 production behavior still asserted by Reader test')

require('CHANGELOG.md', '0.31.0-dev.284', 'Vertical composition cache-boundary retention')
require('CHANGELOG.md', '0.31.0-dev.285', 'dev.284 mount-travel keep-alive behavior')

print('PASS: dev.284 composition-boundary experiment is preserved as superseded history')
