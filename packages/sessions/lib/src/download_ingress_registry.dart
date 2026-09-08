import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:telemetry/telemetry.dart';

import 'download_ingress_projection.dart';
import 'download_session.dart';
import 'webp_decode_prefix_hints.dart';

const int _residentInitialHydrationBytes = 256 * 1024;

final class _IngressProjectionEntry {
  _IngressProjectionEntry({
    required this.session,
    required this.projection,
    this.control,
  }) : completer = Completer<void>();

  DownloadSession session;
  final DownloadIngressProjection projection;
  _IngressAttachmentControl? control;
  final Completer<void> completer;
  Future<void>? attachment;
  Future<void>? residentHydration;
  DownloadSnapshotListener? sessionListener;
  int residentRequestedLength = 0;
  bool active = true;

  int get priority => control?.priority ?? session.effectivePriority;
}

/// Reader-local registry for native ingress projections.
///
/// Physical [DownloadSession] state can outlive any Reader. A Reader joining an
/// already-active/promoted transfer therefore must not synchronously attach a
/// fresh native ingress: replaying an existing committed prefix is asynchronous
/// consumer work. [get] always returns the Reader-local projection immediately
/// and starts a synchronized late join in the background when necessary.
///
/// This keeps physical transfer ownership independent from demand reconciliation
/// and ensures decode/upload can be reconciled even while the local source is
/// still catching up. For nonresident WebP hot partials the projection may publish a decoder-usable
/// prefix before full catch-up; its source listener then becomes the wake edge
/// while the same native source continues suffix replay toward the authoritative
/// committed boundary.
final class DownloadIngressProjectionRegistry {
  DownloadIngressProjectionRegistry({
    required this.sources,
    required this.scopePrefix,
    this.residentReplaySource,
    this.residentReplaySourceWithControl,
    this.residentReplayRangeSource,
    this.residentReplayRangeSourceWithControl,
    this.traceSink = const NoopTraceSink(),
    this.maxActiveReplays = 2,
  }) : assert(maxActiveReplays > 0);

  final SourcePool sources;
  final String scopePrefix;
  final DownloadResidentReplaySource? residentReplaySource;
  final DownloadResidentReplaySourceWithControl?
      residentReplaySourceWithControl;
  final DownloadResidentReplayRangeSource? residentReplayRangeSource;
  final DownloadResidentReplayRangeSourceWithControl?
      residentReplayRangeSourceWithControl;
  final TraceSink traceSink;
  final int maxActiveReplays;
  final Map<DownloadId, _IngressProjectionEntry> _entries =
      <DownloadId, _IngressProjectionEntry>{};
  final List<_IngressProjectionEntry> _pendingReplays =
      <_IngressProjectionEntry>[];
  final Set<_IngressProjectionEntry> _activeReplays =
      <_IngressProjectionEntry>{};

  Iterable<DownloadIngressProjection> get projections =>
      _entries.values.map((entry) => entry.projection);

  DownloadIngressProjection attach(DownloadSession session) {
    final existing = _entries[session.id];
    if (existing != null && identical(existing.session, session)) {
      existing.control?.updatePriority(session.effectivePriority);
      _pumpReplays();
      return existing.projection;
    }
    if (existing != null) {
      // A new physical DownloadSession with the same DownloadId is a new
      // physical object generation. dev.279 only preserves the Reader encoded
      // generation under the sealed immutable exception below.
      final snapshot = existing.projection.snapshot;
      if (existing.attachment == null &&
          !_pendingReplays.contains(existing) &&
          snapshot.sealed &&
          snapshot.sourceReady &&
          snapshot.failure == null) {
        // The physical transfer object changed, but this Reader already owns a
        // complete immutable encoded generation for the same exact DownloadId.
        // Retiring that source would turn a hot Reader re-entry into disk replay
        // + decode/upload regeneration even though the encoded bytes did not
        // change. Physical generation and encoded-source generation are not the
        // same concept once the Reader-local source is sealed.
        existing.session.detachIngressProjection(existing.projection.scopeId);
        existing.session = session;
        existing.attachment = null;
        return existing.projection;
      }
      _pendingReplays.remove(existing);
      _activeReplays.remove(existing);
      existing.active = false;
      existing.control?.cancel();
      if (!existing.completer.isCompleted) {
        existing.completer.complete();
      }
      final existingListener = existing.sessionListener;
      if (existingListener != null) {
        existing.session.removeSnapshotListener(existingListener);
      }
      existing.session.detachIngressProjection(existing.projection.scopeId);
      existing.projection.detach();
      _entries.remove(session.id);
      // An incomplete/failed Reader-local source is still physical-generation
      // bound. A replacement physical session must receive a fresh ingress and
      // revision timeline rather than inheriting a mutable prefix.
      sources.remove(session.id);
    }

    final projection = DownloadIngressProjection(
      scopeId: '$scopePrefix:physical:${session.sessionId}',
      ingress: sources.get(session.id),
      decodePrefixQuantumBytes: _decodePrefixQuantumFor(session),
      decoderDrivenSourceGrowth: session.residentIngressDeferred,
    );
    final attachmentControl = session.committedLength == 0
        ? null
        : _IngressAttachmentControl(priority: session.effectivePriority);
    final entry = _IngressProjectionEntry(
      session: session,
      projection: projection,
      control: attachmentControl,
    );
    // Publish the local projection before starting a late replay. DecodeSession
    // may safely enter waitingSource against this empty projection while the
    // physical prefix is copied; the eventual rebuild notification wakes it.
    _entries[session.id] = entry;
    _observeSession(entry);

    if (session.residentIngressDeferred) {
      try {
        session.attachDeferredResidentIngressProjection(projection);
      } on Object {
        _removeSessionListener(entry);
        _entries.remove(session.id);
        projection.detach();
        rethrow;
      }
      _requestInitialResidentHydration(entry);
      return projection;
    }

    if (session.committedLength == 0) {
      try {
        session.attachIngressProjection(projection);
        entry.completer.complete();
      } on Object {
        _entries.remove(session.id);
        projection.detach();
        rethrow;
      }
      return projection;
    }

    _pendingReplays.add(entry);
    _pumpReplays();
    return projection;
  }

  DownloadIngressProjection get(DownloadSession session) => attach(session);

  DownloadIngressProjection? find(DownloadId id) => _entries[id]?.projection;

  Future<void> settled(DownloadId id) {
    final entry = _entries[id];
    if (entry == null) return Future<void>.value();
    _pumpReplays();
    return entry.completer.future;
  }

  void updatePriority(DownloadSession session) {
    final entry = _entries[session.id];
    if (entry != null && identical(entry.session, session)) {
      entry.control?.updatePriority(session.effectivePriority);
      _pumpReplays();
    }
  }

  void detach(DownloadSession session) {
    final entry = _entries[session.id];
    if (entry == null || !identical(entry.session, session)) return;
    _entries.remove(session.id);
    _pendingReplays.remove(entry);
    _activeReplays.remove(entry);
    entry.active = false;
    entry.control?.cancel();
    if (!entry.completer.isCompleted) {
      entry.completer.complete();
    }
    _removeSessionListener(entry);
    session.detachIngressProjection(entry.projection.scopeId);
    entry.projection.detach();
    _pumpReplays();
  }

  /// Releases this Reader's encoded-source ownership for one physical page.
  ///
  /// Physical transfer/download retention is independent and may continue in
  /// the composition owner. This boundary is used when Pipeline no longer has
  /// any decode/upload demand for the page; it must not be inferred from a
  /// DownloadDemand priority or viewport-role threshold.
  void release(DownloadSession session) {
    final id = session.id;
    final entry = _entries[id];
    if (entry != null && !identical(entry.session, session)) {
      return;
    }
    detach(session);
    if (_entries[id] == null) {
      sources.remove(id);
    }
  }

  /// Releases only Reader-local projection ownership.
  ///
  /// It intentionally does not enumerate or dispose the composition physical
  /// DownloadRegistry. Any in-flight late-join future self-cleans its physical
  /// fan-out when it observes [active] becoming false.
  void dispose() {
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    _pendingReplays.clear();
    _activeReplays.clear();
    for (final entry in entries) {
      entry.active = false;
      entry.control?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete();
      }
      _removeSessionListener(entry);
      entry.session.detachIngressProjection(entry.projection.scopeId);
      entry.projection.detach();
    }
  }

  void _observeSession(_IngressProjectionEntry entry) {
    void listener(DownloadSnapshot snapshot) {
      if (!entry.active || !identical(_entries[entry.session.id], entry)) {
        return;
      }
      entry.control?.updatePriority(snapshot.effectivePriority);
      entry.projection.setDecodePrefixQuantumBytes(
        _decodePrefixQuantumFor(entry.session),
      );
      entry.projection.setDecoderDrivenSourceGrowth(
        entry.session.residentIngressDeferred,
      );
      if (entry.session.residentIngressDeferred &&
          snapshot.state == DownloadState.promoted &&
          snapshot.committedLength > 0) {
        _requestInitialResidentHydration(entry);
      }
    }

    entry.sessionListener = listener;
    entry.session.addSnapshotListener(listener, fireImmediately: false);
  }

  void _removeSessionListener(_IngressProjectionEntry entry) {
    final listener = entry.sessionListener;
    if (listener == null) return;
    entry.session.removeSnapshotListener(listener);
    entry.sessionListener = null;
  }

  void _requestInitialResidentHydration(_IngressProjectionEntry entry) {
    if (!entry.active || !entry.session.residentIngressDeferred) return;
    entry.projection.setDecodePrefixQuantumBytes(
      localWebpDecodePrefixQuantumBytes,
    );
    entry.control ??=
        _IngressAttachmentControl(priority: entry.session.effectivePriority);
    final total = entry.session.committedLength;
    if (total <= 0) return;
    final target = _residentInitialHydrationBytes < total
        ? _residentInitialHydrationBytes
        : total;
    final hydration = _requestResidentHydration(entry, target);
    unawaited(
      hydration.whenComplete(() {
        if (entry.active && !entry.completer.isCompleted) {
          entry.completer.complete();
        }
      }),
    );
  }

  static int? _decodePrefixQuantumFor(DownloadSession session) =>
      session.residentIngressDeferred ? localWebpDecodePrefixQuantumBytes : null;

  /// Extends one already-demanded Reader source to decoder-owned evidence.
  ///
  /// This is not a page-admission policy. The caller has already established
  /// DecodeDemand/UploadDemand; [endExclusive] comes from DecodeSession's
  /// `requiredSourceLength` after native need-more-data evidence.
  Future<void> ensureResidentPrefix(
    DownloadSession session,
    int endExclusive,
  ) {
    final entry = _entries[session.id];
    if (entry == null ||
        !identical(entry.session, session) ||
        !session.residentIngressDeferred ||
        endExclusive <= 0) {
      return Future<void>.value();
    }
    final total = session.committedLength;
    final target = endExclusive < total ? endExclusive : total;
    return _requestResidentHydration(entry, target);
  }

  Future<void> _requestResidentHydration(
    _IngressProjectionEntry entry,
    int target,
  ) {
    if (!entry.active || !entry.session.residentIngressDeferred) {
      return Future<void>.value();
    }
    if (target > entry.residentRequestedLength) {
      entry.residentRequestedLength = target;
    }
    final running = entry.residentHydration;
    if (running != null) return running;
    late final Future<void> tracked;
    tracked = _hydrateResident(entry).catchError((Object error, StackTrace stack) {
      if (!entry.active ||
          !identical(_entries[entry.session.id], entry) ||
          !entry.session.residentIngressDeferred) {
        return;
      }
      final failure = error is Failure
          ? error
          : Failure(
              code: ErrorCode.source,
              message: 'deferred resident ingress hydration failed',
              cause: error,
            );
      _recordResidentHydration(
        entry,
        action: 'failed',
        start: entry.projection.snapshot.length,
        endExclusive: entry.residentRequestedLength,
        error: '$failure',
      );
      entry.projection.fail(failure);
    }).whenComplete(() {
      if (identical(entry.residentHydration, tracked)) {
        entry.residentHydration = null;
      }
      if (entry.active &&
          identical(_entries[entry.session.id], entry) &&
          entry.session.residentIngressDeferred &&
          entry.projection.snapshot.length < entry.residentRequestedLength) {
        unawaited(_requestResidentHydration(
          entry,
          entry.residentRequestedLength,
        ));
      }
    });
    entry.residentHydration = tracked;
    return tracked;
  }

  Future<void> _hydrateResident(_IngressProjectionEntry entry) async {
    final session = entry.session;
    final projection = entry.projection;
    final control = entry.control ??=
        _IngressAttachmentControl(priority: session.effectivePriority);
    control.throwIfCancelled();
    if (!session.residentIngressDeferred ||
        session.state != DownloadState.promoted) {
      return;
    }
    final epoch = session.epoch;
    final total = session.committedLength;
    final current = projection.snapshot.length;
    final requested = entry.residentRequestedLength;
    final target = requested < total ? requested : total;
    if (target <= current) return;
    _recordResidentHydration(
      entry,
      action: 'started',
      start: current,
      endExclusive: target,
    );
    final range = residentReplayRangeSource;
    final controlledRange = residentReplayRangeSourceWithControl;
    if (range == null && controlledRange == null) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'deferred resident ingress range replay is unavailable',
      );
    }
    final chunks = controlledRange != null
        ? await controlledRange(
            session,
            current,
            target,
            control: control,
          )
        : await range!(session, current, target);
    control.throwIfCancelled();
    if (session.epoch != epoch || !session.residentIngressDeferred) return;
    projection.expectLength(session.totalLength);
    if (current == 0) {
      projection.beginSynchronizedReplay();
      await projection.rebuild(
        epoch: epoch,
        chunks: chunks,
        sealed: target == total,
      );
      control.throwIfCancelled();
      if (session.epoch != epoch || !session.residentIngressDeferred) return;
      projection.publishSynchronizedReplayPrefix();
      _recordResidentHydration(
        entry,
        action: 'completed',
        start: current,
        endExclusive: target,
      );
      return;
    }
    var offset = current;
    await for (final chunk in chunks) {
      control.throwIfCancelled();
      if (session.epoch != epoch || !session.residentIngressDeferred) return;
      if (chunk.isEmpty) continue;
      projection.append(epoch: epoch, offset: offset, bytes: chunk);
      offset += chunk.length;
    }
    if (offset != target) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident ingress range replay was short: $offset/$target',
      );
    }
    if (target == total) {
      projection.seal(epoch);
    }
    _recordResidentHydration(
      entry,
      action: 'completed',
      start: current,
      endExclusive: target,
    );
  }

  void _recordResidentHydration(
    _IngressProjectionEntry entry, {
    required String action,
    required int start,
    required int endExclusive,
    String? error,
  }) {
    try {
      traceSink.record(
        traceEvent(
          clock: entry.session.clock,
          sessionId: scopePrefix,
          kind: TraceEventKind.artifactSource,
          identityHash: entry.session.id.key,
          epoch: entry.session.epoch.value,
          payload: <String, Object?>{
            'stage': 'resident-ingress-hydration',
            'action': action,
            'start': start,
            'endExclusive': endExclusive,
            'priority': entry.priority,
            'physicalEffectivePriority': entry.session.effectivePriority,
            'sourceLength': entry.projection.snapshot.length,
            'bodyLength': entry.session.committedLength,
            'boundReadyReplay': entry.session.residentReplayRangeChunks != null,
            'residentReplayAccessMode': entry.session.residentReplayAccessMode,
            if (error != null) 'error': error,
          },
        ),
      );
    } on Object {
      // Diagnostics cannot alter Reader-local ingress ownership.
    }
  }

  void _pumpReplays() {
    if (_pendingReplays.isEmpty ||
        _activeReplays.length >= maxActiveReplays) {
      return;
    }

    _pendingReplays.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      return a.session.id.key.compareTo(b.session.id.key);
    });

    while (_activeReplays.length < maxActiveReplays &&
        _pendingReplays.isNotEmpty) {
      final index = _pendingReplays.indexWhere((entry) => entry.active);
      if (index < 0) {
        _pendingReplays.clear();
        return;
      }
      final entry = _pendingReplays.removeAt(index);
      _startReplay(entry);
    }
  }

  void _startReplay(_IngressProjectionEntry entry) {
    if (!entry.active) return;
    _activeReplays.add(entry);

    final session = entry.session;
    final projection = entry.projection;
    final attachmentControl = entry.control;

    final attachment = session.attachSynchronizedIngressProjection(
      projection,
      control: attachmentControl,
      residentReplayChunks: session.residentBodyBacked
          ? (endExclusive) {
              final replay = residentReplaySource;
              if (replay == null) {
                throw const Failure(
                  code: ErrorCode.invalidState,
                  message: 'resident-cache Reader replay source is unavailable',
                );
              }
              return replay(session, endExclusive);
            }
          : null,
      controlledResidentReplayChunks:
          session.residentBodyBacked &&
                  residentReplaySourceWithControl != null
              ? (endExclusive, {required control}) {
                  return residentReplaySourceWithControl!(
                    session,
                    endExclusive,
                    control: control,
                  );
                }
              : null,
    );
    entry.attachment = attachment;
    unawaited(
      attachment.then<void>((_) {
        // Reader teardown can race the asynchronous replay. If this entry is no
        // longer authoritative, remove any physical fan-out that the replay may
        // just have installed rather than resurrecting a dead Reader consumer.
        if (!entry.active || !identical(_entries[session.id], entry)) {
          session.detachIngressProjection(projection.scopeId);
        }
        if (!entry.completer.isCompleted) {
          entry.completer.complete();
        }
      }).catchError((Object error, StackTrace stackTrace) {
        if (!entry.active || !identical(_entries[session.id], entry)) {
          if (!entry.completer.isCompleted) {
            entry.completer.complete();
          }
          return;
        }
        final failure = error is Failure
            ? error
            : Failure(
                code: ErrorCode.source,
                message: 'Reader ingress projection attachment failed',
                cause: error,
              );
        projection.fail(failure);
        if (!entry.completer.isCompleted) {
          entry.completer.complete();
        }
      }).whenComplete(() {
        _activeReplays.remove(entry);
        _pumpReplays();
      }),
    );
  }
}

final class _IngressAttachmentControl
    implements PriorityObservableTaskControl {
  _IngressAttachmentControl({int priority = 0}) : _priority = priority;

  int _priority;
  final StreamController<int> _priorityChanges =
      StreamController<int>.broadcast(sync: true);

  @override
  int get priority => _priority;

  @override
  Stream<int> get priorityChanges => _priorityChanges.stream;

  void updatePriority(int priority) {
    if (_priority == priority) return;
    _priority = priority;
    if (!_priorityChanges.isClosed) _priorityChanges.add(priority);
  }

  final Completer<void> _cancelledSignal = Completer<void>();

  @override
  bool get cancelled => _cancelledSignal.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    if (!_priorityChanges.isClosed) unawaited(_priorityChanges.close());
  }
}
