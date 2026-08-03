#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.97 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains rejected dev.97 tokens: {found}')


require('apps/app/pubspec.yaml', 'version: 0.31.0+98')
require(
    'packages/reader/lib/src/reader_view.dart',
    'final pagePosition = _pageController.hasClients',
    'final priorStillOverlaps = (priorPosition - index).abs() < 1.0',
    'final observedCollapsedToStable =',
    '_emitObservation(handoffPosition, 0, stableIndex: index);',
    'outgoing page remains transition-owned',
)
forbid(
    'packages/reader/lib/src/reader_view.dart',
    '_emitObservation(index.toDouble(), 0, stableIndex: index);',
)
require(
    'packages/pipeline/lib/src/viewport_phase.dart',
    'this.dominantThreshold = 0.5',
    'target.fraction > current.fraction',
    'new stable page wins an exact tie',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    '_binding?.resyncPlayback();',
    'late current session is resumed',
)
require(
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    'final streamingCache = _cache as ArtifactCacheStreamStore;',
)
require(
    'packages/media/lib/src/ingress.dart',
    'final reservable = source as ExpectedLengthEncodedSource;',
    'final reservable = created as ExpectedLengthEncodedSource;',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    'final timing = frame is FrameDecodeTiming',
    '? frame as FrameDecodeTiming',
)
require(
    'packages/telemetry/lib/src/trace.dart',
    '_sanitizeTraceIdentity',
    "_traceOpaqueSummary('identity', sanitized)",
    'sanitized.length <= 160',
)
require(
    'apps/app/lib/debug_trace.dart',
    '_exportCoalescibleKinds',
    '_exportFrameWindowMicros = 1000000',
    '_exportScrollWindowMicros = 250000',
    "'firstMonotonicMicros'",
    "'coalescedCount'",
    '_exportRangeFields',
    'exportCoalescedCount',
    '..sort((a, b) => a.monotonicMicros.compareTo(b.monotonicMicros))',
)
trace_source = read('apps/app/lib/debug_trace.dart')
export_set = trace_source.split(
    'static const Set<TraceEventKind> _exportCoalescibleKinds', 1
)[1].split('};', 1)[0]
for rejected in (
    'TraceEventKind.taskFailed',
    'TraceEventKind.writerRejected',
    'TraceEventKind.retryScheduled',
    'TraceEventKind.pageOutputReleased',
):
    if rejected in export_set:
        raise SystemExit(f'FAIL: authoritative trace kind was made export-coalescible: {rejected}')

require(
    'tool/prepare_webp.sh',
    'patch --dry-run --batch --forward --fuzz=0',
    'verify_libwebp_vp8_tls_patch.py',
    'EXPECTED="$WEBP_COMMIT|$SOURCE_SHA|$PATCH_SHA"',
)
forbid('tool/prepare_webp.sh', 'apply_libwebp_vp8_tls_patch.py')
require(
    'tool/fetch_webp.sh',
    'WEBP_ARCHIVE_SHA256',
    'WEBP_VP8_DEC_SHA256',
    'rebuilding corrupted libwebp upstream cache',
)

require(
    'packages/reader/test/reader_navigation_test.dart',
    'PageView midpoint ownership must not emit a targetless integer observation',
    'midpointObservation.targetCoverage?.pageIndex',
)
require(
    'packages/pipeline/test/viewport_phase_test.dart',
    'exact midpoint transfers playback to the new stable page',
    'expect(state.dominantPageIndex, 2);',
)
require(
    'packages/sessions/test/reader_binding_test.dart',
    'late upload availability can reproject the saved viewport',
    'binding.resyncPlayback();',
)
require(
    'tool/test_dev93_animation_successor_local_trace.py',
    'expect(coordinator.viewport?.phase, ViewportPhase.dominant);',
    'expect(coordinator.viewport?.dominantPageIndex, 1);',
)
require(
    'apps/app/test/misc_settings_test.dart',
    'debug trace folds high-frequency export samples but preserves errors',
    'expect(log.exportCoalescedCount, 7);',
)
require(
    'packages/telemetry/test/trace_test.dart',
    'trace bounds long local identities without losing stable correlation',
)
require('docs/adr/0081-midpoint-playback-handoff-and-diagnostic-trace.md', '0.31.0-dev.97')
require('docs/audits/dev97-page-handoff-trace-audit.md', '被否决方案清单')
require(
    'docs/audits/dev97-validation-results.md',
    '6486 条',
    '2387 个诊断桶',
    '4099 条高频样本',
)
require(
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/audits/dev97-validation-results.md',
)

print('dev.97 midpoint playback handoff and diagnostic trace ownership: OK')
