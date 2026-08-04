#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(source: str, token: str, label: str) -> None:
    if token not in source:
        raise SystemExit(f'ERROR: {label}: missing {token!r}')


def forbid(source: str, token: str, label: str) -> None:
    if token in source:
        raise SystemExit(f'ERROR: {label}: found {token!r}')


session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
stream = read('packages/pipeline_runtime/lib/src/pipeline_page_stream.dart')
output = read('packages/pipeline_runtime/lib/src/pipeline_page_output.dart')
capability = read('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart')
native = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
media_barrel = read('packages/local_media_ui/lib/local_media_ui.dart')
media_player = read('packages/local_media_ui/lib/src/local_image_player.dart')
native_player = read('packages/local_media_ui/lib/src/native_webp_player.dart')
media_screens = read('packages/local_media_ui/lib/src/local_media_screens.dart')
reader_runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
app_composition = read('apps/app/lib/webp_demo.dart')
sessions = read('packages/sessions/lib/src/upload_session.dart')
upload_registry = read('packages/sessions/lib/src/upload_registry.dart')
analyze = read('tool/analyze.sh')
flutter_tests = read('tool/test_flutter.sh')
workspace = read('pubspec.yaml')

for token in (
    'PipelineMediaRuntimeFactory',
    'factory: _media.sources,',
    'cursors: _media.cursors,',
    'uploader: _media.uploader,',
    'outputs: _media.outputs,',
    'await _media.close();',
):
    require(session, token, 'Pipeline atomic media ownership')
for token in ("package:bridge/bridge.dart", "package:texture_bridge/texture_bridge.dart"):
    forbid(session, token, 'core platform dependency')

for token in ('final class PipelinePageOutputStream', '_uploads.claimPresent(', '_outputs.project(', 'PipelinePageSurface?', '_releaseAfterVisualSwap(', '_deferredClaims', 'WidgetsBinding.instance.addPostFrameCallback', 'WidgetsBinding.instance.scheduleFrame'):
    require(output, token, 'read-only output projection')
for token in ('final EncodedSource', 'EncodedSource? get source', 'source: _session.ingress?.source'):
    forbid(stream, token, 'mutable encoded source projection')
for token in ('textureId', 'handleAddress', 'Pointer<'):
    forbid(capability, token, 'public platform handle')
for token in ('final DecodeId? identity', 'required this.identity'):
    forbid(output, token, 'Presentation decode identity leak')

for token in ('NativeSourceFactory()', 'NativeCursorFactory()', 'AndroidTexturePresenter', '_AndroidTextureUploader', '_FlutterImageUploader'):
    require(native, token, 'native capability implementation')
require(app_composition, 'NativePipelineMediaRuntimeFactory()', 'App atomic capability composition')
for token in ('pipeline_native', 'NativePipelineMediaRuntimeFactory'):
    forbid(media_barrel, token, 'Presentation platform composition')

require(media_screens, 'pageOutput: runtime.pageOutput', 'page output injection')
require(media_player, 'surface.build(', 'opaque surface rendering')
require(reader_runtime, 'pageOutput: _pipeline.pageOutput(asset)', 'Reader output consumption')
require(reader_runtime, 'renderer: _pipeline.renderer', 'renderer capability binding')
require(media_player, "'Pipeline page streams must be paired with their owned output'", 'atomic page capability binding')
for token in ('NativeWebpPlayer(',):
    forbid(read('apps/app/lib/static_demo.dart'), token, 'App Reader direct media implementation')
for token in ('pageStream', 'PipelinePageStream', '_startStreamingNative(', '_waitForStreamingAdvance('):
    forbid(native_player, token, 'legacy Presentation streaming decode')

for token in ('_userPaused', '_viewportFrozen', 'void setPlayback(', '_syncPlaybackPause(', '_notifySnapshot()'):
    require(sessions, token, 'Pipeline playback/output lifecycle')
for token in ('_playbackPaused', '_playbackSpeed', '..setPlayback(', 'session.setPlayback(', 'hasRunnablePlayback', 'playbackRunning'):
    require(upload_registry, token, 'registry-owned atomic playback command')
for token in ('PlaybackState.running', 'playbackState =='):
    forbid(upload_registry, token, 'registry playback timer enum leak')
require(sessions, 'bool get playbackRunning', 'session-owned playback state projection')
for token in ('required double Function() playbackSpeed', 'required bool Function() playbackPaused'):
    forbid(output, token, 'Presentation-owned playback closure')
require(media_player, '_schedulePipelineOutputFirstFrame(', 'post-frame first-output readiness')
require(session, '_uploads.hasRunnablePlayback(ids)', 'runnable playback ticker ownership')

for token in ('packages/pipeline_native',):
    require(workspace, token, 'workspace registration')
    require(analyze, token, 'analyzer registration')
    require(flutter_tests, token, 'test runner registration')

for required in (
    'packages/pipeline_native/test/package_compile_test.dart',
    'packages/pipeline_runtime/test/media_runtime_ownership_test.dart',
    'docs/adr/0061-atomic-pipeline-media-runtime.md',
    'docs/audits/dev77-atomic-pipeline-media-runtime-audit.md',
):
    if not (ROOT / required).is_file():
        raise SystemExit(f'ERROR: dev.77 migration artifact is missing: {required}')

media_output = read('packages/media/lib/src/output.dart')
upload_session = read('packages/sessions/lib/src/upload_session.dart')
require(media_output, 'void release(DecodeId id);', 'uploader identity retirement contract')
for token in ('uploader.release(id);',):
    require(upload_session, token, 'upload lifecycle retirement')
require(native, 'final class _AndroidTextureSlot', 'claim-safe texture slot')
require(native, 'slot.releaseFrame();', 'texture owner release')
require(native, '_retire(slot);', 'per-identity texture retirement')
for token in ('Map<DecodeId, Future<AndroidTextureLease>>', '_leases ='):
    forbid(native, token, 'legacy session-long texture lease map')
for token in ('_pendingReleases', 'await Future.wait<void>(', 'await pool.release('):
    require(native, token, 'claim-safe pooled texture drain')

print('dev.77 atomic Pipeline media ownership: OK')
