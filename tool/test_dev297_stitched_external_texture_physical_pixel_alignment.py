#!/usr/bin/env python3
"""Ownership gate for dev.297 stitched external-texture physical-pixel alignment."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(path: str) -> str: return (ROOT / path).read_text(encoding='utf-8')
def require(path: str, *tokens: str) -> None:
    text = read(path); missing = [token for token in tokens if token not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.297 tokens: {missing}')
def forbid(path: str, *tokens: str) -> None:
    text = read(path); found = [token for token in tokens if token in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.297 tokens: {found}')
require('apps/app/pubspec.yaml','version: 0.31.0+297')
require('apps/app/android/zic-version.properties','versionCode=297')
require('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart','abstract interface class PipelineExternalTextureSurface')
require('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart','implements PipelinePageSurface, PipelineExternalTextureSurface')
require('packages/local_media_ui/lib/src/local_image_player.dart',
        'physicalPixelSnapCorrection(',
        'PhysicalPixelAlignedPresentation(',
        'surface is PipelineExternalTextureSurface',
        'boxIsPhysicalPixelIntegral',
        'MatrixUtils.transformPoint(transform, Offset.zero)',
        'context.paintChild(child, offset + Offset(0, correction))',
        'roundingResidual <= 0.500001',
        'Presentation must never inherit a transient aspect error')
require('packages/local_media_ui/test/media_aspect_viewport_test.dart',
        'continuous fitWidth closes only nearest-physical-pixel rounding residual',
        'physical pixel snap correction rounds paint offset only',
        'continuous fitWidth preserves source aspect across a transient parent extent')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7','backwardEncodedPages: 3','forwardDecodePages: 2','backwardDecodePages: 1')
require('docs/adr/0276-stitched-external-texture-physical-pixel-alignment.md',
        '418个sampled page box','414个global top','-0.49..+0.49px','0.5 physical px')
require('docs/audits/dev297-external-texture-subpixel-jitter-audit.md',
        '414/418','fractional','SurfaceProducer')
require('docs/NEXT_CHAT_HANDOFF.md','# dev.297 后续交接','414个global top','external Texture')
require('docs/ARCHITECTURE.md','paint-time vertical pixel snap')
require('docs/SPEC.md','0.5 physical pixel')
forbid('packages/reader/lib/src/reader_view.dart','presentationExtentAt(')
print('dev.297 stitched external-texture physical-pixel alignment: OK')
