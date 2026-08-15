#!/usr/bin/env python3
"""Guard dev.287 decode-ahead vertical geometry preparation."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def text(path): return (ROOT/path).read_text(encoding='utf-8')
def req(ok,msg):
    if not ok: raise SystemExit(f'FAIL: {msg}')
def require(path,*markers):
    body=text(path); missing=[m for m in markers if m not in body]
    req(not missing,f'{path} missing dev.287 contract: {missing}')

pub=text('apps/app/pubspec.yaml'); m=re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$',pub,re.M)
req(m is not None and int(m.group(1))>=287,'dev.287 app version missing')
props=text('apps/app/android/zic-version.properties'); m=re.search(r'^versionCode=(\d+)\s*$',props,re.M)
req(m is not None and int(m.group(1))>=287,'dev.287 Android version missing')
require('packages/sessions/lib/src/decode_session.dart','this.decodedWidth,','this.decodedHeight,','_decodedWidth ??= frame.width;','_decodedHeight ??= frame.height;','_decodedWidth = null;','_decodedHeight = null;')
require('packages/sessions/lib/src/decode_registry.dart','this.onFrameDecoded','final void Function(DecodeId id, DecodeSnapshot snapshot)? onFrameDecoded;','observer(id, snapshot);')
require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',"part 'pipeline_page_dimensions.dart';",'_pageDimensions = _PipelinePageDimensionsPublisher()','PipelinePageDimensionsFeed get pageDimensions => _pageDimensions','onFrameDecoded: _handleFrameDecoded','void _handleFrameDecoded(DecodeId id, DecodeSnapshot snapshot)','TraceEventKind.pageDimensionsResolved','_pageDimensions.dispose();')
require('packages/pipeline_runtime/lib/src/pipeline_page_dimensions.dart','final class PipelinePageDimensions','abstract interface class PipelinePageDimensionsFeed','bool replay = true','bool publish(PipelinePageDimensions dimensions)')
require('packages/reader_runtime/lib/src/reader_runtime_screen.dart','_pipeline.pageDimensions.addListener(_handlePipelinePageDimensions);','void _handlePipelinePageDimensions(PipelinePageDimensions dimensions)','_reportPageDimensions(asset, dimensions.width, dimensions.height);','_pipeline.pageDimensions.removeListener(_handlePipelinePageDimensions);')
reader=text('packages/reader/lib/src/reader_view.dart')
for marker in ('int? _lastVerticalVisibleMaxIndex;','_adoptFutureVerticalRatios(widget.pageAspectRatios);','void _adoptFutureVerticalRatios(','for (var index = visibleMax + 1; index < pages.length; index++)','TraceEventKind.pageGeometryPrepared',"'source': 'decode-ahead-ratio'"):
    req(marker in reader,f'Reader future geometry preparation missing: {marker}')
for marker in ('reader-vertical-presentation:', 'presentationExtentAt(', 'final presentation = OverflowBox('):
    req(marker not in reader,f'dev.286 presentation workaround remains in Reader: {marker}')
require('packages/reader/test/reader_navigation_test.dart','vertical measured ratios stay frozen until active scrolling is idle','vertical decode-ahead ratios prepare unseen future pages during active scrolling')
require('packages/sessions/test/decode_session_test.dart','result.decodedWidth','result.decodedHeight')
require('packages/telemetry/lib/src/trace.dart','pageDimensionsResolved','pageGeometryPrepared')
for path in ('docs/adr/0266-decode-ahead-vertical-geometry-preparation.md','docs/audits/dev287-decode-ahead-vertical-geometry-audit.md'):
    req((ROOT/path).is_file(),f'missing dev.287 governance file: {path}')
require('docs/ARCHITECTURE.md','decodedWidth/decodedHeight','visible tail之后')
require('docs/SPEC.md','DecodeSession首个成功frame','visible tail之后')
require('docs/IMPLEMENTATION_STATUS.md','dev.287','5.884986s','pageDimensions')
require('docs/IMPLEMENTATION_PLAN.md','dev.287','pageDimensionsResolved','pageGeometryPrepared')
require('docs/NEXT_CHAT_HANDOFF.md','dev.287','300–350ms','pageDimensions')
require('CHANGELOG.md','0.31.0-dev.287','Decode-ahead vertical geometry preparation')
req('test_dev287_decode_ahead_vertical_geometry.py' in text('tool/check.sh'),'dev.287 gate not wired into tool/check.sh')
print('PASS: dev.287 decode-ahead vertical geometry preparation')
