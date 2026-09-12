import 'dart:collection';

import 'package:domain/domain.dart';

const int localWebpDecodePrefixQuantumBytes = 1024 * 1024;
const int remoteWebpDecodePrefixQuantumBytes = 256 * 1024;

int webpDecodePrefixQuantumBytesFor(DownloadId id) {
  final scheme = id.canonicalUri.scheme.toLowerCase();
  return scheme == 'file' || scheme == 'content' || scheme == 'asset'
      ? localWebpDecodePrefixQuantumBytes
      : remoteWebpDecodePrefixQuantumBytes;
}

/// Composition-level retry-floor hints for incremental WebP frame decode.
///
/// The hint is keyed by immutable page identity and frame index. Only an
/// explicit `needMoreData` result proves that a prefix was insufficient, so
/// only that result may advance the reusable retry floor. A successful decode
/// at source length N merely proves that N is sufficient: the source can grow
/// concurrently while decode is queued/running, therefore N is not evidence
/// that every smaller prefix was insufficient and must never become a future
/// Reader's mandatory wait boundary.
///
/// Terminal failures from sealed sources are deliberately excluded: increasing
/// a chunk cannot repair a complete malformed/decoder-state failure.
final class WebpDecodePrefixHints {
  WebpDecodePrefixHints({this.maxEntries = 4096}) : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashMap<_PrefixHintKey, _PrefixHint> _hints =
      LinkedHashMap<_PrefixHintKey, _PrefixHint>();

  int minimumBytes(DownloadId id, int frameIndex) {
    final key = _PrefixHintKey(id, frameIndex);
    final hint = _hints.remove(key);
    if (hint == null) return 0;
    _hints[key] = hint;
    return hint.nextAttemptBytes;
  }

  int recordNeedMoreData({
    required DownloadId id,
    required int frameIndex,
    required int sourceLength,
    int? quantumBytes,
  }) {
    final quantum = quantumBytes ?? webpDecodePrefixQuantumBytesFor(id);
    if (quantum <= 0) {
      throw ArgumentError.value(quantum, 'quantumBytes', 'must be positive');
    }
    final next = _alignUp(sourceLength + 1, quantum);
    final key = _PrefixHintKey(id, frameIndex);
    final prior = _hints.remove(key);
    final required = next > (prior?.nextAttemptBytes ?? 0)
        ? next
        : prior!.nextAttemptBytes;
    _hints[key] = _PrefixHint(nextAttemptBytes: required);
    _trim();
    return required;
  }

  void recordSuccess({
    required DownloadId id,
    required int frameIndex,
    required int sourceLength,
  }) {
    if (sourceLength <= 0) return;
    final key = _PrefixHintKey(id, frameIndex);
    final prior = _hints.remove(key);
    if (prior == null) return;
    // Success can happen after the source has grown well past the boundary the
    // decoder actually requested. Preserve the failure-derived retry floor,
    // but never strengthen it from the opportunistic success length.
    _hints[key] = prior;
  }

  int _alignUp(int value, int quantum) =>
      ((value + quantum - 1) ~/ quantum) * quantum;

  void _trim() {
    while (_hints.length > maxEntries) {
      _hints.remove(_hints.keys.first);
    }
  }
}

final class _PrefixHint {
  const _PrefixHint({required this.nextAttemptBytes});

  final int nextAttemptBytes;
}

final class _PrefixHintKey {
  const _PrefixHintKey(this.id, this.frameIndex);

  final DownloadId id;
  final int frameIndex;

  @override
  bool operator ==(Object other) =>
      other is _PrefixHintKey &&
      other.id == id &&
      other.frameIndex == frameIndex;

  @override
  int get hashCode => Object.hash(id, frameIndex);
}
