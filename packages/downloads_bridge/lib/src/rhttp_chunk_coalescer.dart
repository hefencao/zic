import 'dart:typed_data';

/// Matches the transport framing used by the VibeVenera reference pipeline:
/// expose a small startup prefix quickly, then amortize Dart stream/commit work
/// over larger continuation chunks.
const int rhttpStartupStreamChunkBytes = 64 * 1024;
const int rhttpContinuationStreamChunkBytes = 256 * 1024;

/// Coalesces small Rust/reqwest stream packets into pipeline-sized byte chunks.
///
/// This is transport framing only. It does not own scheduling, retries, caching,
/// or download state, and it deliberately keeps whole incoming packets intact.
final class RhttpChunkCoalescer {
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _emittedChunks = 0;

  int get pendingLength => _pending.length;

  int get targetBytes => _emittedChunks == 0
      ? rhttpStartupStreamChunkBytes
      : rhttpContinuationStreamChunkBytes;

  Uint8List? add(Uint8List chunk) {
    if (chunk.isEmpty) return null;
    _pending.add(chunk);
    if (_pending.length < targetBytes) return null;
    return _takePending();
  }

  Uint8List? flush() => _pending.isEmpty ? null : _takePending();

  Uint8List _takePending() {
    _emittedChunks += 1;
    return _pending.takeBytes();
  }
}
