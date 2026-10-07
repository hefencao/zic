#!/usr/bin/env python3
"""Ownership gate for dev.298 static presentation lifetime across UploadDemand gaps."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
def read(path: str) -> str: return (ROOT / path).read_text(encoding='utf-8')
def require(path: str, *tokens: str) -> None:
    text = read(path); missing = [token for token in tokens if token not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.298 tokens: {missing}')
def forbid(path: str, *tokens: str) -> None:
    text = read(path); found = [token for token in tokens if token in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.298 tokens: {found}')
def current_dev() -> int:
    m = re.search(r'^version: 0\.31\.0\+(\d+)$', read('apps/app/pubspec.yaml'), re.MULTILINE)
    if m is None: raise SystemExit('FAIL: app version missing')
    return int(m.group(1))
dev=current_dev()
require('packages/pipeline_runtime/lib/src/pipeline_page_output.dart',
        'DecodeId? _surfaceIdentity;', '_hasAuthoritativeStaticProjection',
        'DecodeId? retainedStaticIdentity', '_retainOrClearDetachedStaticProjection(',
        '!_disposed && _listeners.isEmpty && _identity == null',
        '_surfaceIdentity == retainedStaticIdentity', '_surfaceIdentity = identity;',
        '_clearProjection(PipelinePageOutputState.idle)')
require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'DecodeId? _activeDecodeIdentity(DownloadId download)', 'retainedStaticIdentity:')
if dev == 298:
    require('apps/app/pubspec.yaml','version: 0.31.0+298')
    require('apps/app/android/zic-version.properties','versionCode=298')
    require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
            'uploadIdentity == null ? _activeDecodeIdentity(id) : null')
elif dev > 298:
    require('docs/archive/adr/0277-static-presentation-upload-demand-lifetime.md', 'UploadDemand membership只拥有presentation claim/retention identity')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7','backwardEncodedPages: 3','forwardDecodePages: 2','backwardDecodePages: 1')
require('packages/local_media_ui/lib/src/local_image_player.dart', 'surface == null', '_loadingIndicator()', 'child: FittedBox(')
forbid('packages/local_media_ui/lib/src/local_image_player.dart', 'PhysicalPixelAlignedPresentation(', 'physicalPixelSnapCorrection(', 'roundingResidual <= 0.500001')
forbid('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart','PipelineExternalTextureSurface')
require('docs/archive/adr/0277-static-presentation-upload-demand-lifetime.md', 'UploadDemand membership只拥有presentation claim/retention identity', '既有decode', 'listener')
require('docs/archive/audits/dev298-static-presentation-demand-gap-audit.md', 'same-frame', 'surface=null', 'loadingIndicator', 'residentReuse=true')
require('docs/ARCHITECTURE.md','UploadDemand membership只拥有presentation claim/retention identity')
require('docs/SPEC.md','UploadDemand membership MUST表示presentation claim/retention identity')
print('dev.298 static presentation upload-demand gap: OK')
