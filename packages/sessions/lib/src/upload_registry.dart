import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'decode_registry.dart';
import 'net_lane.dart';
import 'upload_session.dart';

typedef UploadRegistryListener = void Function(
  DecodeId id,
  UploadSnapshot snapshot,
);

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
  bool _playbackPaused = false;
  double _playbackSpeed = 1;

  final Set<UploadRegistryListener> _listeners =
      <UploadRegistryListener>{};

  Iterable<UploadSession> get sessions => _sessions.values;
  int get totalBytes =>
      _sessions.values.fold<int>(0, (sum, session) => sum + session.outputBytes);

  int bytesFor(Set<DecodeId> ids) => ids.fold<int>(
        0,
        (sum, id) => sum + (_sessions[id]?.outputBytes ?? 0),
      );

  UploadSession? find(DecodeId id) => _sessions[id];

  void addListener(UploadRegistryListener listener) {
    _listeners.add(listener);
  }

  void removeListener(UploadRegistryListener listener) {
    _listeners.remove(listener);
  }

  PresentClaim? claimPresent(DecodeId id) =>
      _sessions[id]?.claimPresent();

  Future<void> present(DecodeId id, PresentClaim claim) async {
    final session = _sessions[id];
    if (session == null) {
      claim.release();
      throw StateError('upload session is unavailable');
    }
    await session.present(claim);
  }

  int preparedDepth(DecodeId id) => _sessions[id]?.preparedDepth ?? 0;

  bool hasRunnablePlayback(Iterable<DecodeId> ids) {
    for (final id in ids) {
      if (_sessions[id]?.playbackRunning == true) {
        return true;
      }
    }
    return false;
  }

  UploadSession get(DecodeId id) {
    return _sessions.putIfAbsent(id, () {
      final session = UploadSession(
        id: id,
        decode: decodes.get(id),
        uploader: uploader,
        clock: clock,
        traceSink: traceSink,
        sessionId: 'upload:${id.key.hashCode}',
      )..setPlayback(
          paused: _playbackPaused,
          speed: _playbackSpeed,
        );
      session.addSnapshotListener(
        (snapshot) => _notify(id, snapshot),
        fireImmediately: false,
      );
      return session;
    });
  }

  Future<UploadSnapshot> prepare(
    DecodeId id,
    UploadDemand demand,
    CancelToken token, {
    required int revision,
  }) {
    return get(id).prepare(
      demand: demand,
      revision: revision,
      cancel: token,
    );
  }

  bool freezePlayback(DecodeId id) {
    return _sessions[id]?.freezePlayback() ?? false;
  }

  bool resumePlayback(DecodeId id) {
    return _sessions[id]?.resumePlayback() ?? false;
  }

  void setPlayback({required bool paused, required double speed}) {
    if (!speed.isFinite || speed < 0.25 || speed > 4) {
      throw ArgumentError.value(
        speed,
        'speed',
        'must be finite and within 0.25..4',
      );
    }
    _playbackPaused = paused;
    _playbackSpeed = speed;
    for (final session in _sessions.values) {
      session.setPlayback(paused: paused, speed: speed);
    }
  }

  int? takeDueFrame(DecodeId id) => _sessions[id]?.takeDueFrame();

  bool advance(DecodeId id, int frameIndex) {
    return _sessions[id]?.advance(frameIndex) ?? false;
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
    _listeners.clear();
  }

  void _notify(DecodeId id, UploadSnapshot snapshot) {
    for (final listener in _listeners.toList(growable: false)) {
      listener(id, snapshot);
    }
  }
}
