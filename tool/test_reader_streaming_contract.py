#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (
    ROOT / 'packages/reader_runtime/lib/src/reader_runtime_screen.dart'
).read_text()
PROGRESS = (
    ROOT / 'packages/reader_runtime/lib/src/reader_download_progress.dart'
).read_text()
CHAPTER_DOWNLOADS = (
    ROOT / 'packages/downloads/lib/src/chapter_downloads.dart'
).read_text()
DOWNLOAD_UI = (ROOT / 'apps/app/lib/download_manager.dart').read_text()
TRACE = (ROOT / 'packages/telemetry/lib/src/trace.dart').read_text()
DOWNLOAD_JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text()
PLAYER_ROOT = ROOT / 'packages/local_media_ui/lib'
PLAYER = '\n'.join(
    path.read_text()
    for path in [
        PLAYER_ROOT / 'local_media_ui.dart',
        *sorted((PLAYER_ROOT / 'src').glob('*.dart')),
    ]
)
READER = (ROOT / 'packages/reader/lib/src/reader_view.dart').read_text()
CONTROLS_TEST = (ROOT / 'apps/app/test/reader_controls_test.dart').read_text()
NAV_TEST = (ROOT / 'packages/reader/test/reader_navigation_test.dart').read_text()
STARTUP = (ROOT / 'apps/app/lib/main.dart').read_text()
LIBRARY = (ROOT / 'apps/app/lib/demo_home_views.dart').read_text()

required_runtime = (
    'SourcePool(',
    'factory: const NativeSourceFactory()',
    'sources: _streamingSources',
    'readerExistingProgressKey',
    'readerNetworkProgressKey',
    'ReaderDownloadProgressPublisher()',
    '_downloadProgress.notifier',
    'downloadSession: _downloads.get(',
    'if (_currentPageSupportsPlayback(reader))',
)

required_progress = (
    'final class ReaderDownloadProgressPublisher',
    'snapshot.state == DownloadState.promoted',
    'committedBytes: snapshot.committedLength',
    'totalBytes: snapshot.totalLength',
    'addPostFrameCallback',
)
required_player = (
    'streamingSession: runtime.downloadSession',
    'initialEngine: widget.streamingSession == null',
    '? WebpPlayerEngine.flutter',
    ': WebpPlayerEngine.native',
    'parseWebpPrefixInfo(prefix)',
    'CursorStepKind.needMoreData',
    '_waitForStreamingAdvance(',
    '_ownsSource = false',
)
for token in required_runtime:
    if token not in RUNTIME:
        raise SystemExit(f'Reader runtime streaming contract missing: {token}')
for token in required_progress:
    if token not in PROGRESS:
        raise SystemExit(f'Reader progress publisher contract missing: {token}')
if 'snapshot.committedLength > 0' in PROGRESS:
    raise SystemExit('Committed cached bytes must not make an idle Reader transfer active')
for token in (
    'pageProgressUnits',
    'final class _ChapterProgressPublisher',
    'session.addSnapshotListener(listener)',
    'await progress.flush()',
):
    if token not in CHAPTER_DOWNLOADS:
        raise SystemExit(f'Chapter streaming progress contract missing: {token}')
for token in (
    'snapshot.receivedBytes == 0',
    'snapshot.fraction',
):
    if token not in DOWNLOAD_UI:
        raise SystemExit(f'Download UI progress contract missing: {token}')
for token in ('_sanitizeTraceString', '_traceOpaqueSummary', "RegExp(r'venera:(comic|chapter):"):
    if token not in TRACE:
        raise SystemExit(f'Trace locator redaction contract missing: {token}')
for token in ('StreamIterator<List<int>>', 'cancel.whenCancelled', 'await iterator.cancel()'):
    if token not in DOWNLOAD_JOB:
        raise SystemExit(f'Explicit streaming cancellation contract missing: {token}')
for token in required_player:
    if token not in PLAYER:
        raise SystemExit(f'WebP streaming contract missing: {token}')
if 'child: _zoomed\n          ? InteractiveViewer(' not in READER:
    raise SystemExit('Reader scale recognizer is not gated behind explicit zoom')
if "static images hide playback-only controls" not in CONTROLS_TEST:
    raise SystemExit('Static-image playback-control regression is missing')
if "scale recognizers must not compete with PageView at scale 1" not in NAV_TEST:
    raise SystemExit('Remote swipe gesture regression is missing')
if "services == null ? 'bootstrap-memory' : 'durable-services'" not in STARTUP:
    raise SystemExit('Non-blocking bootstrap service swap is missing')
if 'importedLibraryLoadingKey' not in LIBRARY or 'Positioned(' not in LIBRARY:
    raise SystemExit('Background library restore indicator is missing')
print('Reader streaming and non-blocking startup contract: OK')
