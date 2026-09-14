#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.95 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains rejected dev.95 tokens: {found}')


require(
    'native/media_core/src/lib.rs',
    'pub const ABI_VERSION: u32 = 6;',
    'zic_source_reserve_capacity',
    'zic_source_reserve(',
    'zic_source_commit(',
    'committed_len',
    'SourceReservation',
    'source_reservation_exposes_only_committed_prefix',
)
require(
    'packages/bridge/lib/src/native_source.dart',
    "'zic_source_reserve_capacity'",
    "'zic_source_reserve'",
    "'zic_source_commit'",
    'destination.asTypedList(bytes.length).setAll(0, bytes)',
    'reserveExpectedLength',
)
forbid(
    'packages/bridge/lib/src/native_source.dart',
    'final data = calloc<Uint8>(bytes.length)',
)
require(
    'packages/storage/lib/src/artifact.dart',
    'IOSink? _sink;',
    'writer.add(bytes);',
    'Future<void> appendOwned(',
    'int start = 0,',
    'int? endExclusive,',
)
require(
    'packages/downloads/lib/src/artifact_cache_store.dart',
    'final class ArtifactCacheStreamEntry',
    'abstract interface class ArtifactCacheBackend',
)
require(
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    '_cache.lookup(id)',
    '_streamedCachedResponse(',
    "'artifact-cache-stream'",
)
require(
    'native/media_core/src/webp.rs',
    'const DEMUX_REFRESH_BYTES: usize = 512 * 1024;',
    'map_rect_endpoints(',
    '.saturating_add(source.width)',
    'config.options.use_scaling = 1;',
    'config.options.scaled_width = width as c_int;',
    'let bytes = self.canvas.clone();',
    'endpoint_mapping_keeps_adjacent_strips_gapless',
)
forbid(
    'native/media_core/src/webp.rs',
    'fn scale_rgba(',
    'source pixel grid',
    'let source_fragment = decode_rgba_threaded',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'artifact.appendOwned(offset, chunk)',
    "'nativeIngressMicros': _pendingNativeIngressMicros",
    "'artifactWriteMicros': _pendingArtifactWriteMicros",
)
require(
    'packages/downloads/test/artifact_cache_transport_test.dart',
    'stream-capable cache bypasses full-page Uint8List reads',
    'expect(cache.fullReads, 0)',
    "'artifact-cache-stream'",
)
require('tool/check.sh', 'test_dev95_vibe_native_ingress_target_canvas.py')
print('dev.95 Vibe native ingress and target-canvas ownership: OK')
