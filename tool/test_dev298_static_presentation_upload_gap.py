#!/usr/bin/env python3
"""Ownership gate for dev.298 static presentation lifetime across UploadDemand gaps."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(path: str) -> str: return (ROOT / path).read_text(encoding='utf-8')
def require(path: str, *tokens: str) -> None:
    text = read(path); missing = [token for token in tokens if token not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.298 tokens: {missing}')
def forbid(path: str, *tokens: str) -> None:
    text = read(path); found = [token for token in tokens if token in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.298 tokens: {found}')
require('apps/app/pubspec.yaml','version: 0.31.0+298')
require('apps/app/android/zic-version.properties','versionCode=298')
require('packages/pipeline_runtime/lib/src/pipeline_page_output.dart',
        'DecodeId? _surfaceIdentity;',
        '_hasAuthoritativeStaticProjection',
        'DecodeId? retainedStaticIdentity',
        '_retainOrClearDetachedStaticProjection(',
        '!_disposed && _listeners.isEmpty && _identity == null',
        '_surfaceIdentity == retainedStaticIdentity',
        '_surfaceIdentity = identity;',
        '_clearProjection(PipelinePageOutputState.idle)')
require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'DecodeId? _activeDecodeIdentity(DownloadId download)',
        'retainedStaticIdentity:',
        'uploadIdentity == null ? _activeDecodeIdentity(id) : null')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7','backwardEncodedPages: 3','forwardDecodePages: 2','backwardDecodePages: 1')
require('packages/local_media_ui/lib/src/local_image_player.dart',
        'surface == null', '_loadingIndicator()', 'child: FittedBox(')
forbid('packages/local_media_ui/lib/src/local_image_player.dart',
       'PhysicalPixelAlignedPresentation(', 'physicalPixelSnapCorrection(', 'roundingResidual <= 0.500001')
forbid('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart','PipelineExternalTextureSurface')
require('docs/adr/0277-static-presentation-upload-demand-lifetime.md',
        'UploadDemand只拥有新的upload/present调度资格', '既有decode', 'listener')
require('docs/audits/dev298-static-presentation-demand-gap-audit.md',
        'same-frame', 'surface=null', 'loadingIndicator', 'residentReuse=true')
require('docs/ARCHITECTURE.md','UploadDemand只拥有新的upload/present调度资格')
require('docs/SPEC.md','UploadDemand MUST只表示新的upload/present调度资格')
require('docs/NEXT_CHAT_HANDOFF.md','# dev.298 后续交接','same-frame resident re-present')
print('dev.298 static presentation upload-demand gap: OK')
