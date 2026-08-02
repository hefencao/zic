#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.92 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.92 tokens: {found}')


require(
    'packages/storage/test/artifact_test.dart',
    '.map((chunk) => chunk.length)\n        .toList();',
)
forbid(
    'packages/storage/test/artifact_test.dart',
    '.map((chunk) => chunk.length)\n        .toList(growable: false);',
)
require(
    'packages/texture_bridge/test/native_texture_viewport_test.dart',
    "home: Center(\n          child: SizedBox(\n            width: 300,",
    'authoritative stitched box fills without a second FittedBox',
)
require(
    'packages/sessions/lib/src/upload_session.dart',
    'bool _awaitingSuccessor = false;',
    'final authoritativeStatic = micros <= 0 &&',
    'animation.complete &&',
    'animation.frameCount <= 1;',
    "'playbackScheduled': _playback.active",
    "'authoritativeStatic': authoritativeStatic",
    'TraceEventKind.playbackCompleted',
    "'outputRetained': _slot != null && !_slot!.frame.disposed",
    'Keep the current renderer output visible until a successor has been',
    '_setState(UploadState.ready, forceNotify: true);',
    'hadOutput ? decode.prepareForOutputLoss() : false;',
)
forbid(
    'packages/sessions/lib/src/upload_session.dart',
    "_playback.start(\n        frameIndex: claim.frame.index,\n        duration: Duration(microseconds: 0)",
)
require(
    'packages/telemetry/lib/src/trace.dart',
    'playbackCompleted,',
)
require(
    'apps/app/lib/debug_trace.dart',
    'TraceEventKind.playbackCompleted',
)
require(
    'packages/sessions/lib/src/playback_timer.dart',
    'if (micros <= 0) {',
    'clear();',
)
require(
    'packages/sessions/test/playback_timer_test.dart',
    'zero duration never creates an immediately due playback frame',
    'expect(timer.state, PlaybackState.idle);',
    'expect(timer.takeDue(1000), isNull);',
)
require(
    'packages/sessions/test/upload_session_test.dart',
    'static zero-duration output remains visible without playback advance',
    'finite animation keeps its final output after decoder end',
    'expect(upload.playbackState, PlaybackState.idle);',
    'expect(upload.takeDueFrame(), isNull);',
    'expect(upload.frame?.index, 0);',
    'expect(upload.preparedDepth, 0);',
    'expect(finalOutput.state, UploadState.ready);',
    'expect(uploader.outputs.single.disposed, isFalse);',
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
    'ImageCache',
    'Uint8List _pageCache',
)
require('tool/check.sh', 'test_dev92_static_finite_output_lifecycle.py')

print('dev.92 static/finite output lifecycle and reported test fixes: OK')
