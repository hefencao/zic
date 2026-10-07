#!/usr/bin/env python3
"""Historical ownership gate for dev.297 physical-pixel alignment and its dev.298 rollback."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(path: str) -> str: return (ROOT / path).read_text(encoding='utf-8')
def require(path: str, *tokens: str) -> None:
    text = read(path); missing = [token for token in tokens if token not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.297 tokens: {missing}')
def forbid(path: str, *tokens: str) -> None:
    text = read(path); found = [token for token in tokens if token in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.297 tokens: {found}')
def current_dev() -> int:
    for line in read('apps/app/pubspec.yaml').splitlines():
        if line.startswith('version:') and '+' in line:
            return int(line.rsplit('+', 1)[1].strip())
    raise SystemExit('FAIL: app version code missing')
dev = current_dev()
require('docs/archive/audits/dev297-external-texture-subpixel-jitter-audit.md', '414/418', 'fractional', 'SurfaceProducer')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7','backwardEncodedPages: 3','forwardDecodePages: 2','backwardDecodePages: 1')
forbid('packages/reader/lib/src/reader_view.dart','presentationExtentAt(')
if dev == 297:
    require('apps/app/android/zic-version.properties','versionCode=297')
    require('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart','abstract interface class PipelineExternalTextureSurface')
    require('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart','implements PipelinePageSurface, PipelineExternalTextureSurface')
    require('packages/local_media_ui/lib/src/local_image_player.dart',
            'physicalPixelSnapCorrection(', 'PhysicalPixelAlignedPresentation(',
            'surface is PipelineExternalTextureSurface', 'roundingResidual <= 0.500001')
    require('docs/archive/adr/0276-stitched-external-texture-physical-pixel-alignment.md',
            '418个sampled page box','414个global top','0.5 physical px')
elif dev >= 298:
    require('docs/archive/adr/0276-stitched-external-texture-physical-pixel-alignment.md',
            'Superseded by dev.298', '明显大于1-2px')
    forbid('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart','PipelineExternalTextureSurface')
    forbid('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart','PipelineExternalTextureSurface')
    forbid('packages/local_media_ui/lib/src/local_image_player.dart',
           'physicalPixelSnapCorrection(', 'PhysicalPixelAlignedPresentation(',
           'roundingResidual <= 0.500001')
else:
    raise SystemExit(f'FAIL: dev.297 gate cannot run for version {dev}')
print('dev.297 stitched external-texture physical-pixel alignment history: OK')
