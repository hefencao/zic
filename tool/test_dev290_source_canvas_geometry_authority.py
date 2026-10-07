#!/usr/bin/env python3
"""Guard dev.290 source-canvas geometry authority without widening decode demand."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path): return (ROOT / path).read_text(encoding='utf-8')
def req(ok, msg):
    if not ok: raise SystemExit(f'FAIL: {msg}')
def require(path, *markers):
    body = text(path)
    missing = [marker for marker in markers if marker not in body]
    req(not missing, f'{path} missing dev.290 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s+0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 290, 'dev.290 app version missing')
app_version = int(m.group(1))
props = text('apps/app/android/zic-version.properties')
m = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(m is not None and int(m.group(1)) >= 290, 'dev.290 Android version missing')

webp = text('packages/media/lib/src/webp_info.dart')
for marker in (
    "if (tag == 'VP8X' && length >= 10)",
    'if (dataOffset + 10 > bytes.length) return null;',
    "if (tag == 'VP8 ' && length >= 10)",
    "if (tag == 'VP8L' && length >= 5)",
    '// Unknown chunks cannot be skipped until their complete payload is',
):
    req(marker in webp, f'partial WebP canvas parser missing: {marker}')
# The generic whole-chunk guard must occur only after the known canvas chunks.
req(webp.find("if (tag == 'VP8 '") < webp.find('if (dataEnd > bytes.length) return null;'),
    'VP8 prefix geometry still waits for the whole compressed chunk')
require(
    'packages/media/test/webp_info_test.dart',
    'reads VP8 canvas before the declared image chunk is complete',
    'expect(info!.width, 640);',
    'expect(info.height, 1200);',
)

require(
    'packages/pipeline_runtime/lib/src/pipeline_page_dimensions.dart',
    'enum PipelinePageDimensionBasis { sourceCanvas, decodedRaster }',
    'required this.basis,',
    'bool get isSourceCanvas => basis == PipelinePageDimensionBasis.sourceCanvas;',
    'prior.basis == PipelinePageDimensionBasis.sourceCanvas',
    'dimensions.basis == PipelinePageDimensionBasis.decodedRaster',
)
pipeline_reader = text('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for marker in (
    'Future<void> _resolveAndPublishPageDimensions(',
    'basis = PipelinePageDimensionBasis.sourceCanvas;',
    "source = 'decode-raster-fallback';",
    "'decodedWidth': decodedWidth,",
    "'decodedHeight': decodedHeight,",
):
    req(marker in pipeline_reader, f'Pipeline source-canvas contract missing: {marker}')
if app_version < 291:
    for marker in (
        'await download.artifact.readPrefix(64)',
        'final info = parseWebpPrefixInfo(prefix);',
        "source = 'webp-prefix-source-canvas';",
    ):
        req(marker in pipeline_reader, f'dev.290 source-canvas implementation missing: {marker}')
else:
    req('await download.artifact.readPrefix(64)' not in pipeline_reader,
        'dev.291+ must not infer source metadata from the session Artifact')
    req('snapshot?.sourceCanvasWidth' in pipeline_reader and
        "source = 'physical-ingress-source-canvas';" in pipeline_reader,
        'dev.291+ must preserve source-canvas authority through physical ingress metadata')

reader = text('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
for marker in (
    'final Map<String, PipelinePageDimensionBasis> _pageAspectBases =',
    'basis: dimensions.basis,',
    'priorBasis == PipelinePageDimensionBasis.sourceCanvas',
    'basis == PipelinePageDimensionBasis.decodedRaster',
    'PipelinePageDimensionBasis basis = PipelinePageDimensionBasis.sourceCanvas',
):
    req(marker in reader, f'Reader dimension authority missing: {marker}')

local = text('packages/local_media_ui/lib/src/local_image_player.dart')
require(
    'packages/local_media_ui/lib/src/local_image_player.dart',
    '// Surface/output dimensions describe the decoded presentation raster, not',
    'if (!authoritative) {',
    'widget.onDimensionsChanged?.call(dimensions);',
)
# Surface dimensions may remain local but must not directly escape as source geometry.
surface_call = "_reportDimensions(\n          surface.width,\n          surface.height,\n          authoritative: false,"
req(surface_call in local, 'surface dimensions are no longer explicitly non-authoritative')

profile = text('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
for marker in (
    'forwardEncodedPages: 7,',
    'backwardEncodedPages: 3,',
    'forwardDecodePages: 2,',
    'backwardDecodePages: 1,',
    'networkConcurrency: 5,',
    'decodeConcurrency: 3,',
    'uploadConcurrency: 2,',
):
    req(marker in profile, f'frozen Reader window/concurrency changed: {marker}')

req((ROOT / 'docs/archive/adr/0269-source-canvas-page-geometry-authority.md').is_file(),
    'missing dev.290 governance file: docs/archive/adr/0269-source-canvas-page-geometry-authority.md')
require(
    'docs/archive/audits/dev290-source-canvas-geometry-audit.md',
    'dev.290',
    'Source-canvas',
    'pageDimensionsResolved',
)
require('docs/ARCHITECTURE.md', 'source canvas', 'decoded raster')
require('docs/SPEC.md', 'source canvas', 'decoded raster')
require('docs/IMPLEMENTATION_STATUS.md', 'source-canvas', 'decoded raster')
require('CHANGELOG.md', '0.31.0-dev.290', 'Source-canvas geometry authority')
req('test_dev290_source_canvas_geometry_authority.py' in text('tool/check.sh'),
    'dev.290 gate not wired into tool/check.sh')
print('PASS: dev.290 source-canvas geometry authority')
