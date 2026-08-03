#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.93 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.93 tokens: {found}')


require(
    'packages/sessions/lib/src/upload_session.dart',
    'return decode.snapshot.animation.frameCount > 1 ? 0 : 1;',
    'Decode may run ahead to its watermark, but upload remains deadline-owned.',
    "'successorDepth': decode.holder?.depth ?? 0",
    "'successorBuffered': (decode.holder?.depth ?? 0) > 0",
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'A predecoded successor can be uploaded immediately.',
    '_wakeUpload(sessionId, id);',
    '_wakeDecode(sessionId, id, force: true);',
)
require(
    'packages/sessions/test/upload_session_test.dart',
    'animated output buffers one successor without early replacement',
    'expect(buffered.depth, 1);',
    'expect(uploader.outputs, hasLength(1));',
    'return CursorBinding(frames: cursor, loop: cursor);',
)
require(
    'packages/sessions/test/reader_binding_test.dart',
    'expect(coordinator.viewport?.phase, ViewportPhase.dominant);',
    'expect(coordinator.viewport?.dominantPageIndex, 1);',
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'authoritative seal are distinct decode opportunities',
)
require(
    'packages/local_media_ui/test/media_aspect_viewport_test.dart',
    'tester.getRect(find.byKey(childKey)).size',
    'continuous fitWidth trusts the authoritative parent geometry',
    'findsNothing',
)
require(
    'packages/texture_bridge/lib/src/android_texture_presenter.dart',
    'required this.roundTripMicros,',
    'final int roundTripMicros;',
    'int get bridgeMicros',
    'final roundTrip = Stopwatch()..start();',
    'roundTripMicros: roundTrip.elapsedMicroseconds,',
)
require(
    'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart',
    "'roundTripMicros': event.roundTripMicros",
    "'bridgeMicros': event.bridgeMicros",
)
require(
    'packages/local_media_ui/lib/src/native_webp_player.dart',
    "'roundTripMicros': event.roundTripMicros",
    "'bridgeMicros': event.bridgeMicros",
)
require(
    'packages/local_media_bridge/lib/src/local_media_bridge.dart',
    'localMediaBridgeProtocolVersion = 5',
    'directPath',
    'RandomAccessFile? reader;',
    'localMediaBridgeChunkBytes',
)
require(
    'packages/local_media_bridge/android/src/main/kotlin/dev/zic/localmedia/LocalMediaBridgePlugin.kt',
    'PROTOCOL_VERSION = 5',
    'isSeekableDescriptor',
    'Os.lseek',
    '"directPath"',
    '"directStart"',
    '"directEndExclusive"',
)
require(
    'packages/local_media_bridge/test/local_media_bridge_test.dart',
    'seekable document descriptor bypasses per-chunk method calls',
    'direct descriptor must not use per-chunk MethodChannel reads',
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
forbid(
    'packages/reader/lib/src/reader_view.dart',
    'lastFrameCache',
    'Uint8List _pageCache',
)
require('tool/check.sh', 'test_dev93_animation_successor_local_trace.py')
print('dev.93 animation successor and local texture trace ownership: OK')
