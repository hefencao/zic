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

  bool hasRetainableStaticOutputForDownload(DownloadId id) {
    for (final entry in _sessions.entries) {
      if (entry.key.download == id && entry.value.hasRetainableStaticOutput) {
        return true;
      }
    }
    return false;
  }

  void addListener(UploadRegistryListener listener) {
    _listeners.add(listener);
  }

  void removeListener(UploadRegistryListener listener) {
    _listeners.remove(listener);
  }

  PresentClaim? claimPresent(DecodeId id) =>
      _sessions[id]?.claimPresent();

  bool reusePresentedStatic(DecodeId id, PresentClaim claim) =>
      _sessions[id]?.reusePresentedStatic(claim) ?? false;

  Future<void> present(DecodeId id, PresentClaim claim) async {
    final session = _sessions[id];
    if (session == null) {
      claim.release();
      throw StateError('upload session is unavailable');
    }
    await session.present(claim);
  }

  int preparedDepth(DecodeId id) => _sessions[id]?.preparedDepth ?? 0;

  bool reusePreparedStaticForDemand(
    DecodeId id,
    UploadDemand demand, {
    required int revision,
  }) =>
      _sessions[id]?.reusePreparedStaticForDemand(
        demand: demand,
        revision: revision,
      ) ??
      false;

  bool hasRunnablePlayback(Iterable<DecodeId> ids) {
    for (final id in ids) {
      if (_sessions[id]?.playbackRunning == true) {
        return true;
      }
    }
    return false;
  }

  int? earliestPlaybackDeadlineMicros(Iterable<DecodeId> ids) {
    int? earliest;
    for (final id in ids) {
      final deadline = _sessions[id]?.playbackDeadlineMicros;
      if (deadline == null) continue;
      if (earliest == null || deadline < earliest) {
        earliest = deadline;
      }
    }
    return earliest;
  }

  /// Returns one session's deadline without scanning the whole Reader window.
  /// Presentation callbacks use this as a cheap hint before rebuilding the
  /// global playback wake for an animated successor.
  int? playbackDeadlineMicros(DecodeId id) =>
      _sessions[id]?.playbackDeadlineMicros;

  UploadSession get(DecodeId id) {
    final decode = decodes.get(id);
    final existing = _sessions[id];
    if (existing != null) {
      if (identical(existing.decode, decode)) {
        return existing;
      }
      // DecodeId is a logical identity; DecodeRegistry may replace the concrete
      // DecodeSession when its physical/source generation changes. UploadSession
      // intentionally binds one DecodeSession for life, so the registry that
      // owns UploadSession lifetime must retire a stale binding before reusing
      // the same logical DecodeId. Do not let callers observe or prepare against
      // a holder owned by a retired decode generation.
      _sessions.remove(id);
      existing.dispose();
    }

    final session = UploadSession(
      id: id,
      decode: decode,
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
    _sessions[id] = session;
    return session;
  }

  Future<UploadSnapshot> prepare(
    DecodeId id,
    UploadDemand demand,
    CancelToken token, {
    required int revision,
    int laneQueueMicros = 0,
  }) {
    return get(id).prepare(
      demand: demand,
      revision: revision,
      cancel: token,
      laneQueueMicros: laneQueueMicros,
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

  bool detach(
    DecodeId id, {
    bool retainStaticOutput = false,
  }) {
    return _sessions[id]?.detach(
          retainStaticOutput: retainStaticOutput,
        ) ??
        false;
  }

  bool evict(DecodeId id) {
    final session = _sessions.remove(id);
    session?.dispose();
    return session != null;
  }

  /// Invalidates upload/output sessions that retain DecodeSession instances
  /// owned by a physical download generation that is being replaced.
  ///
  /// UploadSession intentionally holds one DecodeSession for its lifetime. A
  /// DecodeRegistry generation replacement therefore has to retire dependent
  /// upload sessions before those DecodeSessions are disposed; otherwise a
  /// later upload prepare can keep observing the old, empty holder while the
  /// replacement DecodeSession is already producing frames.
  int invalidateForDownload(DownloadId id) {
    final ids = _sessions.keys
        .where((decodeId) => decodeId.download == id)
        .toList(growable: false);
    for (final decodeId in ids) {
      _sessions.remove(decodeId)?.dispose();
    }
    return ids.length;
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
