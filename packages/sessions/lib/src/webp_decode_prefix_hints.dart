import 'dart:collection';

import 'package:domain/domain.dart';

const int localWebpDecodePrefixQuantumBytes = 1024 * 1024;
const int remoteWebpDecodePrefixQuantumBytes = 256 * 1024;

/// Composition-level minimum-prefix hints for incremental WebP frame decode.
///
/// The hint is keyed by immutable page identity and frame index. A partial
/// source that returns `needMoreData` advances only that frame's threshold by
/// one source-appropriate quantum. A later successful decode records the
/// smallest observed sufficient prefix for reuse after Reader re-entry.
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
    return hint.successfulBytes ?? hint.nextAttemptBytes;
  }

  int recordNeedMoreData({
    required DownloadId id,
    required int frameIndex,
    required int sourceLength,
  }) {
    final quantum = _quantumFor(id);
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
    final priorSuccess = prior?.successfulBytes;
    final successful = priorSuccess == null || sourceLength < priorSuccess
        ? sourceLength
        : priorSuccess;
    _hints[key] = _PrefixHint(
      nextAttemptBytes: successful,
      successfulBytes: successful,
    );
    _trim();
  }

  int _quantumFor(DownloadId id) {
    final scheme = id.canonicalUri.scheme.toLowerCase();
    return scheme == 'file' || scheme == 'content' || scheme == 'asset'
        ? localWebpDecodePrefixQuantumBytes
        : remoteWebpDecodePrefixQuantumBytes;
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
  const _PrefixHint({
    required this.nextAttemptBytes,
    this.successfulBytes,
  });

  final int nextAttemptBytes;
  final int? successfulBytes;
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
