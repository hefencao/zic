import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'decode_session.dart';
import 'download_registry.dart';
import 'net_lane.dart';
import 'webp_decode_prefix_hints.dart';

final class DecodeRegistry {
  DecodeRegistry({
    required this.downloads,
    required this.cursors,
    required this.clock,
    WebpDecodePrefixHints? prefixHints,
    this.onAnimationResolved,
    this.traceSink = const NoopTraceSink(),
  }) : prefixHints = prefixHints ?? WebpDecodePrefixHints();

  final DownloadRegistry downloads;
  final CursorFactory cursors;
  final MonoClock clock;
  final WebpDecodePrefixHints prefixHints;
  final void Function(DecodeId id, AnimationInfo animation)?
      onAnimationResolved;
  final TraceSink traceSink;
  final Map<DecodeId, DecodeSession> _sessions = <DecodeId, DecodeSession>{};

  Iterable<DecodeSession> get sessions => _sessions.values;
  int get totalBytes =>
      _sessions.values.fold<int>(0, (sum, session) => sum + session.bytes);

  int bytesFor(Set<DecodeId> ids) => ids.fold<int>(
        0,
        (sum, id) => sum + (_sessions[id]?.bytes ?? 0),
      );

  DecodeSession? find(DecodeId id) => _sessions[id];

  DecodeSession get(DecodeId id) {
    return _sessions.putIfAbsent(id, () {
      final download = downloads.get(id.download);
      return DecodeSession(
        id: id,
        download: download,
        cursors: cursors,
        clock: clock,
        prefixHints: prefixHints,
        onAnimationResolved: onAnimationResolved,
        traceSink: traceSink,
        sessionId: 'decode:${id.key.hashCode}',
      );
    });
  }

  Future<DecodeSnapshot> fill(
    DecodeId id,
    DecodeDemand demand,
    CancelToken token, {
    required int revision,
    int preparedDepth = 0,
    int laneQueueMicros = 0,
    void Function(DecodeSnapshot snapshot)? onFrameReady,
  }) {
    return get(id).fill(
      demand: demand,
      revision: revision,
      cancel: token,
      preparedDepth: preparedDepth,
      laneQueueMicros: laneQueueMicros,
      onFrameReady: onFrameReady,
    );
  }

  void detach(DecodeId id, {int retainDepth = 1}) {
    _sessions[id]?.detach(retainDepth: retainDepth);
  }

  bool evict(DecodeId id) {
    final session = _sessions.remove(id);
    session?.dispose();
    return session != null;
  }

  void resetFor(DownloadId id, SourceEpoch epoch) {
    for (final entry in _sessions.entries) {
      if (entry.key.download == id) {
        entry.value.reset(epoch);
      }
    }
  }

  void dispose() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
