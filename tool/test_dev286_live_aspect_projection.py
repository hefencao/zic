#!/usr/bin/env python3
"""Guard device supersession of dev.286 live-presentation workaround."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def text(path): return (ROOT/path).read_text(encoding='utf-8')
def req(ok,msg):
    if not ok: raise SystemExit(f'FAIL: {msg}')
pub=text('apps/app/pubspec.yaml'); m=re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$',pub,re.M)
req(m is not None and int(m.group(1))>=286,'dev.286 version lineage missing')
adr=text('docs/adr/0265-live-aspect-projection-over-frozen-vertical-layout.md')
req('状态：Superseded' in adr and 'dev.287' in adr,'dev.286 ADR must be superseded by device evidence')
geometry=text('packages/reader/lib/src/vertical_reader_geometry.dart')
reader=text('packages/reader/lib/src/reader_view.dart')
for marker in ('double presentationExtentAt(', '_computeExtent(index, presentationRatios)'):
    req(marker not in geometry,f'superseded dev.286 geometry remains: {marker}')
for marker in ('reader-vertical-presentation:', 'final presentation = OverflowBox(', 'presentationDiffers'):
    req(marker not in reader,f'superseded dev.286 Reader workaround remains: {marker}')
req('return geometry.extentAt(pageIndex);' in reader,'vertical item extent no longer owned by geometry')
req('MUST NOT恢复dev.286' in text('docs/SPEC.md'),'SPEC does not record dev.286 workaround supersession')
req('test_dev286_live_aspect_projection.py' in text('tool/check.sh'),'dev.286 supersession gate not wired')
print('PASS: dev.286 live-aspect workaround superseded by dev.287')
