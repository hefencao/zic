#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.99 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains rejected dev.99 tokens: {found}')


require(
    'packages/media/lib/src/frame.dart',
    'abstract interface class FrameDecodeTiming',
    'int get workerReadyMicros;',
    'int get workerQueueMicros;',
    'int get nativeDecodeMicros;',
    'int get nativeMetadataMicros;',
)
require(
    'packages/bridge/lib/src/native_decode_pool.dart',
    'workerReady: Stopwatch()..start(),',
    'workerReadyMicros = workerReady.elapsedMicroseconds;',
    'debugName: \'zic-webp-decode-$index\'',
    'final metadataStopwatch = Stopwatch()..start();',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    'final class DecodedFrameTiming',
    'var remainingLaneQueueMicros =',
    'remainingLaneQueueMicros = 0;',
    '_waitingSourceSinceMicros ??= clock.nowMicros();',
    'workerReadyMicros: timing?.workerReadyMicros ?? 0',
    "'sourceWaitMicros': frameTiming.sourceWaitMicros",
    "'nativeMetadataMicros': frameTiming.nativeMetadataMicros",
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    "'laneQueueMicros': decodeLaneQueueMicros",
    "'executionMicros':",
    "'taskElapsedMicros':",
    '...details,',
)
require(
    'packages/media/lib/src/output.dart',
    'enum FramePresentationPath { platform, flutterFallback }',
    'final int platformUploadMicros;',
    'final int platformResultDispatchMicros;',
    'final int fallbackDecodeMicros;',
)
require(
    'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart',
    'final platformAttempt = Stopwatch()..start();',
    'platformUploadMicros: sample.uploadMicros',
    'path: FramePresentationPath.platform',
    'path: FramePresentationPath.flutterFallback',
)
require(
    'packages/sessions/lib/src/upload_session.dart',
    'TraceEventKind.framePipelineTiming',
    'final Map<int, int> _startupFrameOrdinals',
    '_startupFrameOrdinals.length < 12',
    'endToEndMicros >= 250000',
    'presentMicros >= 100000',
    'dominant.value >= 100000',
    "'workerReadyMicros': decoded?.workerReadyMicros ?? 0",
    "'platformUploadMicros': platform?.platformUploadMicros ?? 0",
    "'platformOtherMicros': platformOtherMicros",
    "'platformResultDispatchMicros':",
    "'fallbackDecodeMicros': platform?.fallbackDecodeMicros ?? 0",
    "'presentationPath': platform?.path.name ?? 'unknown'",
    "'decodeStartedAtMicros': decoded?.decodeStartedAtMicros ?? 0",
    "'presentedAtMicros': presentedAtMicros",
    '_framePipelineTimings.remove(uploaded.index);',
)
require(
    'apps/app/lib/debug_trace.dart',
    'TraceEventKind.framePipelineTiming',
    "'workerReadyMicros'",
    "'platformUploadMicros'",
    "'platformOtherMicros'",
    "'fallbackDecodeMicros'",
)
debug_trace = read('apps/app/lib/debug_trace.dart')
export_set = debug_trace.split(
    'static const Set<TraceEventKind> _exportCoalescibleKinds', 1
)[1].split('};', 1)[0]
if 'TraceEventKind.framePipelineTiming' in export_set:
    raise SystemExit('FAIL: exact startup frame timing was made export-coalescible')

require(
    'packages/downloads/lib/src/artifact_cache_store.dart',
    'const int promotedArtifactReadChunkBytes = 1024 * 1024;',
)
require(
    'packages/downloads/lib/src/chapter_downloads.dart',
    'const chunkSize = promotedArtifactReadChunkBytes;',
    'Stream<List<int>> _readIndexedChunks(',
    '.clamp(1, promotedArtifactReadChunkBytes)',
)
require(
    'apps/app/lib/comic_details.dart',
    'final result = Completer<bool>();',
    '_refreshInFlight = tracked;',
    'Future<bool>.sync(',
    'await _setRead(entry, true)',
    'comicDetailsRetryBodyKey',
)
forbid('apps/app/lib/comic_details.dart', 'comicDetailsRetryKey')
require(
    'packages/pipeline/lib/src/raster_plan.dart',
    'Small sources remain at their',
    'bool get prefersNearestNeighbor',
)
require(
    'apps/app/test/misc_settings_test.dart',
    'frame pipeline timing remains exact in export',
    'notifiedDuringBuild',
)
require(
    'packages/sessions/test/upload_session_test.dart',
    "pipelineTiming.payload['workerReadyMicros']",
    "pipelineTiming.payload['platformOtherMicros']",
    "pipelineTiming.payload['platformResultDispatchMicros']",
)
require(
    'tool/analyze_frame_pipeline_trace.py',
    'framePipelineTiming',
    'dominantStageCounts',
    'workerReadyMicros',
)
require('tool/check.sh', 'test_dev99_frame_pipeline_timing.py')
require('tool/check.sh', 'test_frame_pipeline_trace_analyzer.py')
require('docs/adr/0083-frame-pipeline-timing-and-local-artifact-ingress.md', '0.31.0-dev.99')
require('docs/audits/dev99-frame-pipeline-timing-audit.md', '被否决方案清单')
require('docs/audits/dev99-validation-results.md', 'framePipelineTiming')

print('dev.99 exact frame pipeline timing and local artifact ingress: OK')
