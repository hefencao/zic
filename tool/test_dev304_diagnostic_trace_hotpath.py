#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.304 missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.304 forbidden {label}: {token}')


telemetry = read('packages/telemetry/lib/src/trace.dart')
debug_trace = read('apps/app/lib/debug_trace.dart')
misc_page = read('apps/app/lib/misc_page.dart')
pipeline = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
telemetry_test = read('packages/telemetry/test/trace_test.dart')
app_test = read('apps/app/test/misc_settings_test.dart')
runtime_test = read('packages/pipeline_runtime/test/media_runtime_ownership_test.dart')

for token in (
    "import 'dart:collection';",
    'final ListQueue<TraceEvent> _events = ListQueue<TraceEvent>();',
    "if (sanitized.contains('venera'))",
    "if (sanitized.contains('mihon:'))",
    'final RegExp _veneraResourceTracePattern = RegExp(',
    'final RegExp _veneraEntityTracePattern = RegExp(',
    'final RegExp _mihonEntityTracePattern = RegExp(',
):
    require(telemetry, token, 'precompiled sanitized bounded telemetry')

for token in (
    'final ListQueue<TraceEvent> _events = ListQueue<TraceEvent>();',
    'final ListQueue<_TraceExportEntry> _exportEvents =',
    'final Map<String, _TraceExportEntry> _exportBuckets =',
    'final removed = _exportEvents.removeFirst();',
    'identical(_exportBuckets[removedKey], removed)',
    'for (final entry in event.payload.entries)',
    '!hasListeners',
    'int get exportEventCount => _exportEvents.length;',
    'TraceEventKind.readerFrameTiming,',
    '_isHealthyReaderFrameTiming',
    '_forgetReaderFrameTimingBucket',
    "'layoutSampleAgeMicros'",
):
    require(debug_trace, token, 'constant-time DebugTrace projection')
for token in (
    'removeRange(0,',
    '_exportBaseIndex',
    'for (final field in _exportRangeFields)',
):
    forbid(debug_trace, token, 'linear saturated DebugTrace hot path')

require(misc_page, 'debugTrace.exportEventCount',
        'constant-time trace summary count')

require(pipeline, 'trace = traceSink ?? const NoopTraceSink();',
        'explicit production trace sink')
require(pipeline, 'sharedPhysicalTraceSink: _sharedTraceSink,',
        'shared physical trace de-duplication')
forbid(pipeline, '_memoryTrace', 'unconsumed unbounded Reader trace copy')

require(telemetry_test,
        'bounded memory trace evicts oldest events in constant-size order',
        'bounded MemoryTrace regression')
require(app_test,
        'debug trace forgets coalescing buckets when their event is evicted',
        'export bucket eviction regression')
require(app_test,
        'debug trace without a viewer does not request a Flutter frame',
        'headless trace frame regression')
require(runtime_test, "import 'package:pipeline/pipeline.dart';",
        'DecodeTarget owner import')

all_docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0283-diagnostic-trace-ui-isolate-hotpath.md',
    'docs/audits/dev304-diagnostic-trace-hotpath-root-cause-audit.md',
))
for token in ('O(1)', 'RegExp', 'hasListeners', 'MemoryTraceSink'):
    require(all_docs, token, 'governed diagnostic hot path')

pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
pub_match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', version_props, re.M)
if pub_match is None or int(pub_match.group(1)) < 304:
    raise SystemExit('dev.304+ app version mismatch')
if android_match is None or int(android_match.group(1)) < 304:
    raise SystemExit('dev.304+ Android version mismatch')

print('dev.304 diagnostic trace UI-isolate hot path: OK')
