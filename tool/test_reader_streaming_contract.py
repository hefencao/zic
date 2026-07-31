#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (ROOT / 'apps/app/lib/reader_runtime.dart').read_text()
PLAYER = (ROOT / 'apps/app/lib/webp_demo.dart').read_text()
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
    '_sessionExistingBytes',
    'committedBytes: snapshot.committedLength',
    'downloadSession: _downloads.get(',
    'if (_currentPageSupportsPlayback(reader))',
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
