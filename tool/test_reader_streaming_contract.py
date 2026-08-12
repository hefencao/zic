#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (ROOT / 'packages/reader_runtime/lib/src/reader_runtime_screen.dart').read_text()
PIPELINE_RUNTIME = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart').read_text()
PIPELINE_HOST = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_host.dart').read_text()
PAGE_STREAM = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_stream.dart').read_text()
PAGE_OUTPUT = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_output.dart').read_text()
PROGRESS = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart').read_text()
CHAPTER_DOWNLOADS = (ROOT / 'packages/downloads/lib/src/chapter_downloads.dart').read_text()
DOWNLOAD_UI = (ROOT / 'apps/app/lib/download_manager.dart').read_text()
TRACE = (ROOT / 'packages/telemetry/lib/src/trace.dart').read_text()
DOWNLOAD_JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text()
PLAYER_ROOT = ROOT / 'packages/local_media_ui/lib'
PLAYER = '\n'.join(path.read_text() for path in [PLAYER_ROOT / 'local_media_ui.dart', *sorted((PLAYER_ROOT / 'src').glob('*.dart'))])
READER = (ROOT / 'packages/reader/lib/src/reader_view.dart').read_text()
CONTROLS_TEST = (ROOT / 'apps/app/test/reader_controls_test.dart').read_text()
NAV_TEST = (ROOT / 'packages/reader/test/reader_navigation_test.dart').read_text()
STARTUP = (ROOT / 'apps/app/lib/main.dart').read_text()
LIBRARY = (ROOT / 'apps/app/lib/demo_home_views.dart').read_text()

for token in (
    'required this.pipeline',
    'PipelineReaderSession get _pipeline => widget.pipeline',
    '_pipeline.enqueueObservation',
    '_pipeline.loadBytes(asset, token)',
    '_pipeline.pageStream(asset)',
    '_pipeline.pageOutput(asset)',
    'PipelineTransferProgress',
):
    if token not in RUNTIME:
        raise SystemExit(f'Reader projection contract missing: {token}')
for token in ('final class PipelineReaderSessionHost', '_ownerFactory.acquire(', '_ownerFactory.release(_session)'):
    if token not in PIPELINE_HOST:
        raise SystemExit(f'Pipeline host ownership contract missing: {token}')
if 'onObservation: _pipeline.accept' in RUNTIME:
    raise SystemExit('Reader runtime must not synchronously reconcile Pipeline from UI observation callbacks')
for forbidden in ('PipelineReaderSessionFactory', 'pipelineFactory', '_pipeline.dispose()', '_pipeline.selectPage', 'transferProgress.select'):
    if forbidden in RUNTIME:
        raise SystemExit(f'Reader retained pipeline composition: {forbidden}')
for token in (
    'LiveCoordinator(', 'SourcePool(', 'DecodeRegistry(',
    'UploadRegistry(', 'FrameBudgeter(', 'ReaderBinding(',
    'PipelinePageStream.forDownload', '_syncPageStreams();', 'PipelinePageOutputStream._(',
    'PipelineTransferProgressPublisher()', 'transferProgress.select(',
):
    if token not in PIPELINE_RUNTIME:
        raise SystemExit(f'Pipeline runtime ownership contract missing: {token}')
for token in ('CompositionDownloadTransferRuntime', '_downloads = _transferRuntime.registry;'):
    if token not in PIPELINE_RUNTIME:
        raise SystemExit(f'Pipeline physical-transfer consumer boundary missing: {token}')
if '_downloads.get' in PIPELINE_RUNTIME:
    raise SystemExit('Pipeline presentation/read-only paths must not create physical download sessions')
for forbidden in ('DownloadRegistry', 'DownloadSession', 'LiveCoordinator', 'NetLane(', 'DecodeLane(', 'UploadLane(', "package:downloads/", "package:sessions/", "package:storage/", "package:transport/", "package:media/"):
    if forbidden in RUNTIME:
        raise SystemExit(f'Reader regained pipeline ownership: {forbidden}')
for token in ('final class PipelinePageStream', 'PipelinePageStreamSnapshot', 'Future<Uint8List> readPrefix', 'void refreshBinding()', 'required DownloadSession? Function() resolvePhysical'):
    if token not in PAGE_STREAM:
        raise SystemExit(f'Pipeline page-stream projection missing: {token}')
for forbidden in ('final EncodedSource', 'EncodedSource? get source', ' get source'):
    if forbidden in PAGE_STREAM:
        raise SystemExit(f'Pipeline transfer projection leaked mutable media: {forbidden}')
for token in ('final class PipelinePageOutputStream', 'PipelinePageSurface?', '_uploads.claimPresent(', '_outputs.project('):
    if token not in PAGE_OUTPUT:
        raise SystemExit(f'Pipeline page-output projection missing: {token}')
for token in ('final class PipelineTransferProgressPublisher', 'snapshot.state == DownloadState.promoted', 'partialBytes: snapshot.committedLength', 'transportBytes: snapshot.networkCursorLength', 'totalBytes: snapshot.totalLength', 'addPostFrameCallback'):
    if token not in PROGRESS:
        raise SystemExit(f'Pipeline progress publisher contract missing: {token}')
if 'snapshot.committedLength > 0' in PROGRESS:
    raise SystemExit('Cached committed bytes must not make an idle transfer active')
for token in ('pageProgressUnits', 'final class _ChapterProgressPublisher', 'session.addSnapshotListener(listener)', 'await progress.flush()'):
    if token not in CHAPTER_DOWNLOADS:
        raise SystemExit(f'Chapter streaming progress contract missing: {token}')
for token in ('snapshot.receivedBytes == 0', 'snapshot.fraction'):
    if token not in DOWNLOAD_UI:
        raise SystemExit(f'Download UI progress contract missing: {token}')
for token in ('_sanitizeTraceString', '_traceOpaqueSummary', "RegExp(r'venera:(comic|chapter):"):
    if token not in TRACE:
        raise SystemExit(f'Trace locator redaction contract missing: {token}')
for token in ('StreamIterator<List<int>>', 'cancel.whenCancelled', 'await iterator.cancel()'):
    if token not in DOWNLOAD_JOB:
        raise SystemExit(f'Explicit streaming cancellation contract missing: {token}')
for token in ('pageStream: runtime.pageStream', 'pageOutput: runtime.pageOutput', 'PipelinePageOutputStream? pageOutput', 'parseWebpPrefixInfo(prefix)', 'surface.build('):
    if token not in PLAYER:
        raise SystemExit(f'WebP Pipeline projection contract missing: {token}')
for forbidden in ('stream.source', 'pageStream?.source', '_startStreamingNative(', '_waitForStreamingAdvance(', '_ownsSource = false'):
    if forbidden in PLAYER:
        raise SystemExit(f'Presentation regained Pipeline decode/source ownership: {forbidden}')
if 'child: _zoomed\n          ? InteractiveViewer(' not in READER:
    raise SystemExit('Reader scale recognizer is not gated behind explicit zoom')
if 'static images hide playback-only controls' not in CONTROLS_TEST:
    raise SystemExit('Static-image playback-control regression is missing')
if 'scale recognizers must not compete with PageView at scale 1' not in NAV_TEST:
    raise SystemExit('Remote swipe gesture regression is missing')
if "services == null ? 'bootstrap-memory' : 'durable-services'" not in STARTUP:
    raise SystemExit('Non-blocking bootstrap service swap is missing')
if 'importedLibraryLoadingKey' not in LIBRARY or 'Positioned(' not in LIBRARY:
    raise SystemExit('Background library restore indicator is missing')
print('Pipeline-owned Reader streaming/output and non-blocking startup contract: OK')
