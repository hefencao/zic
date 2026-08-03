#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.91 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.91 tokens: {found}')


require(
    'packages/telemetry/lib/src/trace.dart',
    'sourceRead,',
    'pageOutputReleased,',
    'playbackFrameDue,',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    'bool prepareForOutputLoss()',
    '_restartAfterDetach = true;',
    "'decodeMicros':",
    "'sourceLength': frameTiming.sourceLength",
)
require(
    'packages/sessions/lib/src/upload_session.dart',
    'bool detach()',
    "reason: 'demand-detached'",
    "reason: 'frame-budget'",
    'decode.prepareForOutputLoss()',
    "'uploadMicros':",
    "'presentMicros':",
    'TraceEventKind.playbackFrameDue',
    "'lateByMicros':",
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'final decodeRestarted = uploads?.detach(id) ?? false;',
    'if (decodeDemanded && decodeRestarted)',
    'after.state == UploadState.waitingFrame',
)
require(
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    "sourceClass: 'persistent-artifact'",
    "return 'local-document';",
    "return 'local-file';",
    'TraceEventKind.sourceRead',
    "'firstChunkMicros':",
    "'maxChunkGapMicros':",
    "'minChunkBytes':",
    "'maxChunkBytes':",
    "'consumer': 'session-copy'",
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'TraceEventKind.sourceRead',
    '_recordPresentationCacheRead(',
    "source: 'session-artifact'",
    "'consumer': 'pipeline-presentation'",
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'retired output re-primes a consumed static frame before page revisit',
    'expect(cursors.created, 2);',
    "expect(released.payload['decodeRestarted'], isTrue);",
    'expect(uploader.outputs, hasLength(2));',
)
forbid(
    'packages/sessions/test/live_coordinator_test.dart',
    'PageRole.preDecode',
)
require(
    'packages/sessions/test/upload_session_test.dart',
    "event.kind == TraceEventKind.frameUploaded",
    "event.kind == TraceEventKind.pageOutputReleased",
    "expect(upload.detach(), isTrue);",
)
require(
    'packages/downloads/test/artifact_cache_transport_test.dart',
    "event.kind == TraceEventKind.sourceRead",
    "expect(read.payload['sourceClass'], 'persistent-artifact');",
    "expect(read.payload['maxChunkGapMicros'], isA<int>());",
)
require(
    'packages/sessions/test/playback_timer_test.dart',
    'reports playback lateness only while a frame is running',
    'timer.lateByUs(12000)',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
    'networkConcurrency: 5',
    'decodeConcurrency: 3',
    'uploadConcurrency: 2',
)
require('tool/check.sh', 'test_dev91_page_revisit_local_trace.py')

print('dev.91 page revisit and local/cached media trace ownership: OK')
