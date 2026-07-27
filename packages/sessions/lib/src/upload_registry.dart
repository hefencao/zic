import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'decode_registry.dart';
import 'net_lane.dart';
import 'upload_session.dart';

final class UploadRegistry {
  UploadRegistry({
    required this.decodes,
    required this.uploader,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
  });

  final DecodeRegistry decodes;
  final FrameUploader uploader;
  final MonoClock clock;
  final TraceSink traceSink;
  final Map<DecodeId, UploadSession> _sessions = <DecodeId, UploadSession>{};

  Iterable<UploadSession> get sessions => _sessions.values;

  UploadSession? find(DecodeId id) => _sessions[id];

  UploadSession get(DecodeId id) {
    return _sessions.putIfAbsent(id, () {
      return UploadSession(
        id: id,
        decode: decodes.get(id),
        uploader: uploader,
        clock: clock,
        traceSink: traceSink,
        sessionId: 'upload:${id.key.hashCode}',
      );
    });
  }

  Future<void> prepare(
    DecodeId id,
    UploadDemand demand,
    CancelToken token, {
    required int revision,
  }) async {
    await get(id).prepare(
      demand: demand,
      revision: revision,
      cancel: token,
    );
  }

  void detach(DecodeId id) {
    _sessions[id]?.detach();
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
