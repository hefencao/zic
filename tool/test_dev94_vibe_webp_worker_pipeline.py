#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.94 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains rejected dev.94 tokens: {found}')


require(
    'packages/bridge/lib/src/native_source.dart',
    "import 'dart:isolate';",
    "part 'native_decode_pool.dart';",
)
require(
    'packages/bridge/lib/src/native_decode_pool.dart',
    '_nativeDecodeWorkerCount = 2',
    'Isolate.spawn<List<Object?>>',
    "debugName: 'zic-webp-decode-$index'",
    'cursorAddress',
    'frameAddress',
    "message == 'close'",
    'api.decode(cursor, epoch, out)',
    'for (final worker in started)',
    'response.close();',
)
require(
    'packages/bridge/lib/src/native_cursor.dart',
    '_NativeDecodeWorkerPool.forLibrary(libPath)..acquire()',
    'await _decodePool.decode(',
    'Pointer<_Frame>.fromAddress(result.frameAddress)',
    '_decodePool.release();',
    'nativeDecodeMicros: result.nativeMicros',
    'dispatchMicros:',
)
forbid(
    'packages/bridge/lib/src/native_cursor.dart',
    'final raw = _api.decode(',
    'calloc<Pointer<_Frame>>()',
)
require(
    'packages/media/lib/src/frame.dart',
    'abstract interface class FrameDecodeTiming',
    'int get nativeDecodeMicros;',
    'int get dispatchMicros;',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    "'nativeDecodeMicros': frame is FrameDecodeTiming",
    "'decodeDispatchMicros': frame is FrameDecodeTiming",
)
require(
    'native/media_core/src/webp.rs',
    'struct FrameDescriptor',
    'struct DemuxSnapshot',
    'frames: Vec<FrameDescriptor>',
    'source_length: usize',
    'fragment_offset',
    'self.demux = Some(DemuxSnapshot::parse(bytes, sealed)?);',
    'sealed_source_reuses_demux_across_frames_and_rewind',
    'config.options.use_threads = 1;',
    'WebPInitDecoderConfigInternal',
    'map_rect_endpoints(',
    'bytes: self.canvas.clone(),',
)
forbid(
    'native/media_core/src/webp.rs',
    'let mut next_canvas = self.canvas.clone();',
    'let demux = Demux(demux_ptr);\n        self.meta',
    'scale_rect(',
    'bytes.to_vec().into_boxed_slice()',
    'bytes: Box<[u8]>',
)
require(
    'tools/webp_decoder_smoke.c',
    'decode_rgba_threaded',
    'config.options.use_threads = 1;',
    'WebPDecode(bytes, size, &config)',
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
require('tool/check.sh', 'test_dev94_vibe_webp_worker_pipeline.py')
print('dev.94 VibeVenera-derived WebP worker pipeline ownership: OK')
