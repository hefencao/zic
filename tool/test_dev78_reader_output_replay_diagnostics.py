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


capability = read('packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart')
upload_registry = read('packages/sessions/lib/src/upload_registry.dart')
upload_session = read('packages/sessions/lib/src/upload_session.dart')
decode_session = read('packages/sessions/lib/src/decode_session.dart')
native_runtime = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
webp = read('native/media_core/src/webp.rs')
webp_ffi = read('native/media_core/src/lib.rs')
comic_details = read('apps/app/lib/comic_details.dart')
demo_home = read('apps/app/lib/demo_home.dart')
reader_route = read('apps/app/lib/demo_home_reader_route.dart')
trace_log = read('apps/app/lib/debug_trace.dart')
trace_screen = read('apps/app/lib/debug_trace_screen.dart')
trace_export = read('apps/app/lib/debug_trace_export.dart')
trace_tests = read('apps/app/test/misc_settings_test.dart')
source_tests = read('apps/app/test/source_browser_test.dart')
decode_tests = read('packages/sessions/test/decode_session_test.dart')
upload_tests = read('packages/sessions/test/upload_session_test.dart')

require(capability, "import 'package:domain/domain.dart';", 'RendererKind compile closure')
require(capability, 'RendererKind get renderer;', 'RendererKind runtime contract')
require(upload_session, 'bool get playbackRunning', 'session playback projection')
require(upload_registry, '_sessions[id]?.playbackRunning == true', 'registry playback projection')
for token in ('PlaybackState.running', 'playbackState =='):
    forbid(upload_registry, token, 'registry internal playback enum leak')

for token in (
    'max_width: usize',
    'max_height: usize',
    'fn fit_dimensions(',
    'self.max_width,',
    'self.max_height,',
    'self.ensure_canvas(\n            prepared.background,\n            prepared.source_width,\n            prepared.source_height,\n        )?;',
):
    require(webp, token, 'aspect-preserving native decode')
for token in (
    'fit_dimensions(4000, 1000, 1000, 1000)',
    'fit_dimensions(1000, 4000, 1000, 1000)',
    'animated_webp_fits_inside_decode_bounds_without_stretching',
):
    require(webp + webp_ffi, token, 'native decode geometry regression')
for token in (
    'width: frame.width,',
    'height: frame.height,',
    'slot.width != frame.width',
    'slot.height != frame.height',
):
    require(native_runtime, token, 'actual output texture dimensions')
for token in ('width: id.physicalWidth', 'height: id.physicalHeight'):
    forbid(native_runtime, token, 'viewport-sized texture stretching')
for token in (
    'candidate.width != claim.frame.width',
    'candidate.height != claim.frame.height',
    'candidate.width > id.physicalWidth',
    'candidate.height > id.physicalHeight',
):
    require(upload_session, token, 'fitted output validation')

for token in (
    'bool _restartCursorWhenHolderEmpty = false;',
    '_restartCursorWhenHolderEmpty = true;',
    'if (_restartCursorWhenHolderEmpty && (_holder?.depth ?? 0) == 0)',
    '_releaseBinding();',
):
    require(decode_session, token, 'decode replay lifecycle')
require(decode_tests, 'detached static page recreates its cursor on the next demand', 'decode replay regression')
require(upload_tests, 'accepts an aspect-fitted output inside DecodeId bounds', 'fitted output regression')

for token in ('_pageCountPreflight', '_startPageCountPreflight', 'pageCountLoading', 'pageCountFailed'):
    forbid(comic_details, token, 'chapter body page-count preflight')
require(source_tests, 'pending page counts do not preflight chapter bodies', 'chapter preflight regression')
require(source_tests, 'expect(source.chapterLoads, 0);', 'chapter preflight request count')
require(reader_route, 'unawaited(_markChapterReadForNavigation(current));', 'non-blocking read persistence')
ensure_owner = demo_home.split('Future<ImportedLibraryEntry> _ensureSourceChapter(', 1)[1].split('Future<ImportedLibraryEntry> _refreshRemoteEntry(', 1)[0]
forbid(ensure_owner, 'await _reloadLibrary();', 'chapter manifest navigation reload')
for token in ('await _markChapterReadForNavigation(current)',):
    forbid(demo_home, token, 'read persistence navigation block')

for token in (
    'this.maxExportEvents = 10000',
    'final ListQueue<_TraceExportEntry> _exportEvents',
    'List<TraceEvent> get exportEvents',
    'int get exportDroppedCount',
    '_exportEvents.addLast(entry);',
    '_exportEvents.removeFirst();',
):
    require(trace_log, token, 'bounded raw trace export ring')
for token in (
    '_filteredEvents(log.exportEvents)',
    'DebugTraceEventsExporter',
    'DebugTraceClipboardWriter',
    'Trace 导出失败：$error',
):
    require(trace_screen, token, 'raw trace export capability')
require(trace_export, 'exportDebugTraceEvents', 'raw trace platform export facade')
require(trace_export, 'application/x-ndjson', 'raw trace export MIME')
require(
    trace_tests,
    'debug trace copy uses the diagnostic export ring',
    'diagnostic trace copy regression',
)
require(
    trace_tests,
    'debug trace file export uses the diagnostic export ring',
    'diagnostic trace file regression',
)

for required in (
    'docs/adr/0062-aspect-preserving-replay-and-raw-diagnostics.md',
    'docs/audits/dev78-reader-output-replay-and-diagnostics-audit.md',
):
    if not (ROOT / required).is_file():
        raise SystemExit(f'ERROR: dev.78 migration artifact is missing: {required}')

print('dev.78 Reader output, replay and diagnostics ownership: OK')
