import 'package:sessions/sessions.dart';

import 'pipeline_frame_scheduler.dart';

enum PipelineTransferPhase {
  idle,
  connecting,
  replayingPrefix,
  receiving,
}

final class PipelineTransferProgress {
  const PipelineTransferProgress({
    this.active = false,
    this.partialBytes = 0,
    this.transportBytes = 0,
    this.totalBytes,
    this.transportTotalBytes,
    this.transportAttemptSequence = 0,
    this.transportAttemptActive = false,
    this.speedBytesPerSecond = 0,
  });

  /// Authoritative physical partial already safe for decode/resume.
  ///
  /// This is the straight progress layer. It is monotonic within a physical
  /// DownloadSession and is never inferred from transport activity.
  final int partialBytes;

  /// Absolute byte cursor consumed by the current physical transport attempt.
  ///
  /// This may restart behind [partialBytes] when Range is ignored and a
  /// full-body response must replay the existing prefix. It is deliberately a
  /// transient projection, not a second partial or resume authority.
  final int transportBytes;
  /// Full-body display scale already known from local state.
  ///
  /// This prefers durable response metadata but may fall back to a container
  /// length declared by locally available encoded bytes. It is read-only
  /// presentation state, never a resume/seal/cache authority.
  final int? totalBytes;

  /// Full-body length reported by the current transport attempt.
  ///
  /// This is presentation-only attempt metadata. In a full-body catch-up it
  /// can be known before the preserved partial is verified against that
  /// response, so it must not be used as durable artifact authority.
  final int? transportTotalBytes;
  final int transportAttemptSequence;
  final bool transportAttemptActive;
  final double speedBytesPerSecond;
  final bool active;

  PipelineTransferPhase get phase {
    if (!active) return PipelineTransferPhase.idle;
    if (!transportAttemptActive) return PipelineTransferPhase.connecting;
    if (transportBytes < partialBytes) {
      return PipelineTransferPhase.replayingPrefix;
    }
    return PipelineTransferPhase.receiving;
  }

  bool get replayingPrefix => phase == PipelineTransferPhase.replayingPrefix;

  int? get displayTotalBytes {
    final attemptTotal = transportAttemptActive ? transportTotalBytes : null;
    if (attemptTotal != null && attemptTotal > 0) return attemptTotal;
    final durableTotal = totalBytes;
    return durableTotal != null && durableTotal > 0 ? durableTotal : null;
  }

  double? get partialFraction {
    final total = displayTotalBytes;
    return total == null || total <= 0
        ? null
        : (partialBytes / total).clamp(0.0, 1.0).toDouble();
  }

  double? get transportFraction {
    final total = displayTotalBytes;
    return total == null || total <= 0
        ? null
        : (transportBytes / total).clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PipelineTransferProgress &&
          active == other.active &&
          partialBytes == other.partialBytes &&
          transportBytes == other.transportBytes &&
          totalBytes == other.totalBytes &&
          transportTotalBytes == other.transportTotalBytes &&
          transportAttemptSequence == other.transportAttemptSequence &&
          transportAttemptActive == other.transportAttemptActive &&
          speedBytesPerSecond == other.speedBytesPerSecond;

  @override
  int get hashCode => Object.hash(
        active,
        partialBytes,
        transportBytes,
        totalBytes,
        transportTotalBytes,
        transportAttemptSequence,
        transportAttemptActive,
        speedBytesPerSecond,
      );
}

PipelineTransferProgress pipelineTransferProgressFor(
  DownloadSnapshot snapshot, {
  double speedBytesPerSecond = 0,
}) {
  final scheme = snapshot.id.canonicalUri.scheme.toLowerCase();
  if (scheme == 'file' || scheme == 'content' || scheme == 'asset') {
    return const PipelineTransferProgress();
  }
  if (snapshot.state == DownloadState.sealed ||
      snapshot.state == DownloadState.promoted ||
      snapshot.state == DownloadState.failed ||
      snapshot.state == DownloadState.disposed) {
    return const PipelineTransferProgress();
  }
  final active = snapshot.state == DownloadState.receiving ||
      snapshot.state == DownloadState.queued;
  if (!active && snapshot.committedLength <= 0) {
    return const PipelineTransferProgress();
  }
  return PipelineTransferProgress(
    active: active,
    partialBytes: snapshot.committedLength,
    transportBytes: snapshot.networkCursorLength,
    totalBytes:
        snapshot.totalLength ?? snapshot.localEncodedTotalLengthHint,
    transportTotalBytes: snapshot.networkAttemptTotalLength,
    transportAttemptSequence: snapshot.networkAttemptSequence,
    transportAttemptActive: snapshot.networkAttemptActive,
    speedBytesPerSecond: speedBytesPerSecond,
  );
}

/// Read-only transfer-progress projection exposed by Pipeline.
typedef PipelineTransferProgressListener = void Function(
  PipelineTransferProgress value,
);

final class PipelineTransferProgressFeed {
  PipelineTransferProgressFeed(PipelineTransferProgress initial)
      : _value = initial;

  final Set<PipelineTransferProgressListener> _listeners =
      <PipelineTransferProgressListener>{};
  PipelineTransferProgress _value;
  bool _disposed = false;

  PipelineTransferProgress get value => _value;

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(
    PipelineTransferProgressListener listener, {
    bool fireImmediately = true,
  }) {
    if (_disposed) {
      throw StateError('pipeline transfer progress feed is disposed');
    }
    _listeners.add(listener);
    if (fireImmediately) listener(_value);
  }

  void removeListener(PipelineTransferProgressListener listener) {
    _listeners.remove(listener);
  }

  void _publish(PipelineTransferProgress value) {
    if (_disposed || _value == value) return;
    _value = value;
    for (final listener in _listeners.toList(growable: false)) {
      listener(value);
    }
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
  }
}

/// Pipeline-owned current-page transfer projection.
///
/// DownloadSession remains authoritative for both the durable/playable partial
/// and the transient transport cursor. This publisher selects only the
/// resolved physical session and adds VibeVenera-style smoothed transport
/// speed for presentation; it never owns download or resume state. Frame
/// coalescing is delegated through [PipelineFrameScheduler], so this runtime
/// projection does not import Flutter notifier or scheduler types.
final class PipelineTransferProgressPublisher {
  PipelineTransferProgressPublisher({
    required PipelineFrameScheduler frameScheduler,
  })  : _frameScheduler = frameScheduler,
        feed = PipelineTransferProgressFeed(
          const PipelineTransferProgress(),
        );

  final PipelineFrameScheduler _frameScheduler;
  final PipelineTransferProgressFeed feed;
  DownloadSession? _selectedSession;
  DownloadSnapshotListener? _selectedListener;
  bool _scheduled = false;
  bool _presentationSatisfied = false;
  bool _disposed = false;
  int? _sampleAttemptSequence;
  int _sampleBytes = 0;
  int _sampleMs = 0;
  double _speedBytesPerSecond = 0;

  /// Selects the authoritative physical transfer for the current page.
  void select(DownloadSession? session) {
    if (_disposed || identical(_selectedSession, session)) return;
    final previous = _selectedSession;
    final previousListener = _selectedListener;
    if (previous != null && previousListener != null) {
      previous.removeSnapshotListener(previousListener);
    }
    _selectedSession = session;
    _selectedListener = null;
    _resetSpeedSample();
    if (session != null) {
      void listener(DownloadSnapshot _) => _requestPublish();
      _selectedListener = listener;
      session.addSnapshotListener(listener, fireImmediately: false);
    }
    _requestPublish(preferImmediate: true);
  }

  void clear() {
    select(null);
    setPresentationSatisfied(false);
  }

  /// Hides physical transfer activity from the Reader loading projection after
  /// the current external-static presentation identity has produced a real
  /// visible frame. This is presentation-only: DownloadSession/network state
  /// continues unchanged and becomes visible again when the identity changes
  /// or the presentation is explicitly reloaded/recovered.
  void setPresentationSatisfied(bool value) {
    if (_disposed || _presentationSatisfied == value) return;
    _presentationSatisfied = value;
    _requestPublish(preferImmediate: true);
  }

  void _requestPublish({bool preferImmediate = false}) {
    if (_disposed) return;
    // The feed keeps its latest value for a later fire-immediate attachment,
    // but an unobserved progress projection must not enqueue a post-frame
    // callback (or force an extra frame) while the Reader is composing pages.
    if (!feed.hasListeners) {
      _scheduled = false;
      _publishNow();
      return;
    }
    final frameBusy = _frameScheduler.inPersistentCallbacks ||
        _frameScheduler.hasScheduledFrame;
    final canPublishNow = !frameBusy;
    if (canPublishNow &&
        (preferImmediate || _frameScheduler.isIdle || !_scheduled)) {
      _scheduled = false;
      _publishNow();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    _frameScheduler.afterFrame(() {
      _scheduled = false;
      if (!_disposed) _publishNow();
    });
    // The current frame will drain the post-frame callback when the scheduler
    // is already transient/persistent or a frame is queued. Requesting one
    // more frame in that window only adds an avoidable UI turn.
    if (!frameBusy) {
      _frameScheduler.requestFrame();
    }
  }

  void _publishNow() {
    if (_presentationSatisfied) {
      _set(const PipelineTransferProgress());
      return;
    }
    final session = _selectedSession;
    if (session == null) {
      _set(const PipelineTransferProgress());
      return;
    }
    final snapshot = session.snapshot;
    _sampleSpeed(snapshot);
    _set(
      pipelineTransferProgressFor(
        snapshot,
        speedBytesPerSecond: _speedBytesPerSecond,
      ),
    );
  }

  void _sampleSpeed(DownloadSnapshot snapshot) {
    if (!snapshot.networkAttemptActive) {
      _resetSpeedSample();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final sequence = snapshot.networkAttemptSequence;
    final cursor = snapshot.networkCursorLength;
    if (_sampleAttemptSequence != sequence || cursor < _sampleBytes) {
      _sampleAttemptSequence = sequence;
      _sampleBytes = cursor;
      _sampleMs = now;
      _speedBytesPerSecond = 0;
      return;
    }
    if (cursor == _sampleBytes || now <= _sampleMs) {
      return;
    }
    final instant = (cursor - _sampleBytes) * 1000.0 / (now - _sampleMs);
    _speedBytesPerSecond = _speedBytesPerSecond <= 0
        ? instant
        : _speedBytesPerSecond * 0.7 + instant * 0.3;
    _sampleBytes = cursor;
    _sampleMs = now;
  }

  void _resetSpeedSample() {
    _sampleAttemptSequence = null;
    _sampleBytes = 0;
    _sampleMs = 0;
    _speedBytesPerSecond = 0;
  }

  void _set(PipelineTransferProgress value) {
    if (!_disposed) feed._publish(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final session = _selectedSession;
    final listener = _selectedListener;
    if (session != null && listener != null) {
      session.removeSnapshotListener(listener);
    }
    _selectedSession = null;
    _selectedListener = null;
    _resetSpeedSample();
    feed._dispose();
  }
}
