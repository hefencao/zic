import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:sessions/sessions.dart';

enum PipelineTransferPhase { idle, connecting, receiving }

@immutable
final class PipelineTransferProgress {
  const PipelineTransferProgress({
    this.active = false,
    this.existingBytes = 0,
    this.committedBytes = 0,
    this.totalBytes,
  });

  final bool active;
  final int existingBytes;
  final int committedBytes;
  final int? totalBytes;

  PipelineTransferPhase get phase {
    if (!active) {
      return PipelineTransferPhase.idle;
    }
    return committedBytes > existingBytes
        ? PipelineTransferPhase.receiving
        : PipelineTransferPhase.connecting;
  }

  int get receivedBytes =>
      (committedBytes - existingBytes).clamp(0, committedBytes).toInt();

  double? get existingFraction {
    final total = totalBytes;
    return total == null || total <= 0
        ? null
        : (existingBytes / total).clamp(0.0, 1.0).toDouble();
  }

  double? get committedFraction {
    final total = totalBytes;
    return total == null || total <= 0
        ? null
        : (committedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PipelineTransferProgress &&
          active == other.active &&
          existingBytes == other.existingBytes &&
          committedBytes == other.committedBytes &&
          totalBytes == other.totalBytes;

  @override
  int get hashCode =>
      Object.hash(active, existingBytes, committedBytes, totalBytes);
}

PipelineTransferProgress pipelineTransferProgressFor(
  DownloadSnapshot snapshot,
) {
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
  if (!active) {
    return const PipelineTransferProgress();
  }
  return PipelineTransferProgress(
    active: true,
    existingBytes: snapshot.networkStartLength
        .clamp(0, snapshot.committedLength)
        .toInt(),
    committedBytes: snapshot.committedLength,
    totalBytes: snapshot.totalLength,
  );
}

/// Pipeline-owned current-page projection copied from VibeVenera's progress-publisher shape.
///
/// DownloadSession remains authoritative. The publisher selects the resolved
/// physical session, coalesces chunk notifications to a frame, and immediately hides
/// promoted artifacts so cached page changes never flash a network indicator.
final class PipelineTransferProgressPublisher {
  PipelineTransferProgressPublisher()
      : notifier = ValueNotifier<PipelineTransferProgress>(
          const PipelineTransferProgress(),
        );

  final ValueNotifier<PipelineTransferProgress> notifier;
  DownloadSession? _selectedSession;
  DownloadSnapshotListener? _selectedListener;
  bool _scheduled = false;
  bool _disposed = false;

  /// Selects the authoritative physical transfer for the current page.
  ///
  /// Exact Reader identities may be acquire-time aliases of an older physical
  /// [DownloadSession]. Progress therefore follows the resolved session itself
  /// rather than keeping a second exact-id keyed projection table.
  void select(DownloadSession? session) {
    if (_disposed || identical(_selectedSession, session)) return;
    final previous = _selectedSession;
    final previousListener = _selectedListener;
    if (previous != null && previousListener != null) {
      previous.removeSnapshotListener(previousListener);
    }
    _selectedSession = session;
    _selectedListener = null;
    if (session != null) {
      void listener(DownloadSnapshot _) => _requestPublish();
      _selectedListener = listener;
      session.addSnapshotListener(listener, fireImmediately: false);
    }
    _requestPublish(preferImmediate: true);
  }

  void clear() => select(null);

  void _requestPublish({bool preferImmediate = false}) {
    if (_disposed) return;
    final scheduler = SchedulerBinding.instance;
    final phase = scheduler.schedulerPhase;
    final canPublishNow = phase != SchedulerPhase.persistentCallbacks;
    if (canPublishNow &&
        (preferImmediate || phase == SchedulerPhase.idle || !_scheduled)) {
      _scheduled = false;
      _publishNow();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    scheduler.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) _publishNow();
    });
  }

  void _publishNow() {
    final session = _selectedSession;
    if (session == null) {
      _set(const PipelineTransferProgress());
      return;
    }
    _set(pipelineTransferProgressFor(session.snapshot));
  }

  void _set(PipelineTransferProgress value) {
    if (!_disposed && notifier.value != value) notifier.value = value;
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
    notifier.dispose();
  }
}
