#!/usr/bin/env python3
"""Guard dev.288 Pipeline dimension projection compile/ownership closure."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def text(path): return (ROOT/path).read_text(encoding='utf-8')
def req(ok,msg):
    if not ok: raise SystemExit(f'FAIL: {msg}')
def require(path,*markers):
    body=text(path); missing=[m for m in markers if m not in body]
    req(not missing,f'{path} missing dev.288 contract: {missing}')

pub=text('apps/app/pubspec.yaml'); m=re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$',pub,re.M)
req(m is not None and int(m.group(1))>=288,'dev.288 app version missing')
props=text('apps/app/android/zic-version.properties'); m=re.search(r'^versionCode=(\d+)\s*$',props,re.M)
req(m is not None and int(m.group(1))>=288,'dev.288 Android version missing')

session=text('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for forbidden in (
    "import 'package:flutter/widgets.dart';",
    "import 'package:flutter/foundation.dart';",
    'ValueListenable<Map<String, PipelinePageDimensions>>',
    'ValueNotifier<Map<String, PipelinePageDimensions>>',
    'chapter.pages.indexWhere(',
):
    req(forbidden not in session,f'PipelineReaderSession retains presentation/index-scan coupling: {forbidden}')
for marker in (
    "part 'pipeline_page_dimensions.dart';",
    '_pageDimensions = _PipelinePageDimensionsPublisher()',
    'PipelinePageDimensionsFeed get pageDimensions => _pageDimensions;',
    '_pageIndexByPageId = _indexChapterPages(chapter)',
    '_pageIndexByPageId[id.download.content.pageId]',
    '_pageIndexByPageId[id.content.pageId]',
    'Map<String, int> _indexChapterPages(ChapterManifest chapter)',
    "throw StateError('duplicate Reader pageId: ${page.pageId}');",
    'final changed = _pageDimensions.publish(',
):
    req(marker in session,f'PipelineReaderSession dimension boundary missing: {marker}')

feed=text('packages/pipeline_runtime/lib/src/pipeline_page_dimensions.dart')
for marker in (
    "part of 'pipeline_reader_session.dart';",
    'final class PipelinePageDimensions',
    'required this.pageIndex,',
    'required this.assetKey,',
    'abstract interface class PipelinePageDimensionsFeed',
    'typedef PipelinePageDimensionsListener = void Function(',
    'bool replay = true,',
    'final class _PipelinePageDimensionsPublisher',
    'bool publish(PipelinePageDimensions dimensions)',
    'listener(dimensions);',
):
    req(marker in feed,f'dimension feed contract missing: {marker}')
for forbidden in ('ValueListenable', 'ValueNotifier', 'package:flutter/'):
    req(forbidden not in feed,f'dimension feed leaks Flutter notifier dependency: {forbidden}')

reader=text('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
for marker in (
    '_pipeline.pageDimensions.addListener(_handlePipelinePageDimensions);',
    'void _handlePipelinePageDimensions(PipelinePageDimensions dimensions)',
    'final pageIndex = dimensions.pageIndex;',
    'if (asset.assetKey != dimensions.assetKey) return;',
    '_pipeline.pageDimensions.removeListener(_handlePipelinePageDimensions);',
):
    req(marker in reader,f'Reader dimension consumer closure missing: {marker}')
for forbidden in ('_syncPipelinePageDimensions', '_pipeline.pageDimensions.value'):
    req(forbidden not in reader,f'Reader still depends on pull-based Flutter notifier dimensions: {forbidden}')

require('packages/pipeline_runtime/lib/src/asset_bundle_transport.dart',
        'factory AssetBundleTransport.root() => AssetBundleTransport(rootBundle);')
for path in (
    'docs/archive/adr/0267-pipeline-dimension-projection-boundary.md',
    'docs/archive/audits/dev288-pipeline-dimension-projection-compile-audit.md',
):
    req((ROOT/path).is_file(),f'missing dev.288 governance file: {path}')
require('docs/ARCHITECTURE.md','PipelinePageDimensionsFeed','ValueNotifier','ValueListenable')
require('docs/SPEC.md','PipelinePageDimensionsFeed','ValueListenable')
require('docs/IMPLEMENTATION_STATUS.md','ValueListenable','pageDimensions')
require('CHANGELOG.md','0.31.0-dev.288','Pipeline dimension projection boundary')
req('test_dev288_pipeline_dimension_projection_boundary.py' in text('tool/check.sh'),'dev.288 gate not wired into tool/check.sh')
print('PASS: dev.288 Pipeline dimension projection compile/ownership closure')
