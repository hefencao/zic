import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';

import 'artifact_cache_read_scheduler.dart';

/// Application-composition owner for cross-consumer download resources.
///
/// Network, persistent local-read, and storage-write/migration capacity remain
/// separate physical domains. Storage writes yield to Reader foreground local
/// reads between bounded quanta without consuming or pausing network slots.
final class DownloadResourceCoordinator {
  factory DownloadResourceCoordinator({
    NetLane? networkLane,
    ArtifactCacheReadScheduler? localReadScheduler,
    StorageWriteScheduler? storageWriteScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
  }) {
    final reads = localReadScheduler ?? ArtifactCacheReadScheduler();
    return DownloadResourceCoordinator._(
      networkLane ??
          NetLane(
            maxActive: 5,
            reservedHighPrioritySlots: 1,
            highPriorityThreshold: 1000,
            preemptionThreshold: 40,
            preemptionCandidateGrace: const Duration(milliseconds: 100),
          ),
      reads,
      storageWriteScheduler ?? StorageWriteScheduler(localReadScheduler: reads),
      speculativeEncodedReadBudget ?? SpeculativeEncodedReadBudget(),
    );
  }

  const DownloadResourceCoordinator._(
    this.networkLane,
    this.localReadScheduler,
    this.storageWriteScheduler,
    this.speculativeEncodedReadBudget,
  );

  final NetLane networkLane;
  final ArtifactCacheReadScheduler localReadScheduler;
  final StorageWriteScheduler storageWriteScheduler;
  final SpeculativeEncodedReadBudget speculativeEncodedReadBudget;
}

/// Process-composition capacity domain for durable storage writes/migrations.
///
/// A caller acquires one lease for one bounded read/write quantum, releases it,
/// then reacquires before the next quantum. Foreground local-read pressure is
/// checked before each lease so a migration that started earlier can finish its
/// current bounded chunk but cannot continuously occupy storage I/O afterward.
final class StorageWriteScheduler {
  StorageWriteScheduler({
    required this.localReadScheduler,
    this.maxActive = 1,
  }) : assert(maxActive > 0);

  final ArtifactCacheReadScheduler localReadScheduler;
  final int maxActive;

  final List<_PendingStorageWrite> _pending = <_PendingStorageWrite>[];
  int _active = 0;
  int _sequence = 0;

  int get activeCount => _active;
  int get pendingCount => _pending.length;

  Future<StorageWriteLease> acquireQuantum({TaskControl? control}) async {
    while (true) {
      await localReadScheduler.waitForForegroundRelief(control: control);
      final lease = await _acquireCapacity(control: control);
      if (!localReadScheduler.foregroundPressure) return lease;
      lease.release();
    }
  }

  Future<StorageWriteLease> _acquireCapacity({TaskControl? control}) {
    if (control?.cancelled == true) {
      return Future<StorageWriteLease>.error(const Failure(
        code: ErrorCode.cancelled,
        message: 'storage write was cancelled while waiting for capacity',
      ));
    }
    if (_active < maxActive && _pending.isEmpty) {
      return Future<StorageWriteLease>.value(_start());
    }
    final completer = Completer<StorageWriteLease>();
    final pending = _PendingStorageWrite(
      sequence: _sequence++,
      completer: completer,
      control: control,
    );
    _pending.add(pending);
    if (control != null) {
      unawaited(
        control.whenCancelled.then<void>((_) {
          if (completer.isCompleted || !_pending.remove(pending)) return;
          completer.completeError(const Failure(
            code: ErrorCode.cancelled,
            message: 'storage write was cancelled while waiting for capacity',
          ));
          _pump();
        }),
      );
    }
    _pump();
    return completer.future;
  }

  StorageWriteLease _start() {
    _active++;
    var released = false;
    return StorageWriteLease._(() {
      if (released) return;
      released = true;
      _active--;
      _pump();
    });
  }

  void _pump() {
    for (final pending in _pending
        .where((pending) => pending.control?.cancelled == true)
        .toList(growable: false)) {
      _pending.remove(pending);
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(const Failure(
          code: ErrorCode.cancelled,
          message: 'storage write was cancelled while waiting for capacity',
        ));
      }
    }
    _pending.sort((left, right) => left.sequence.compareTo(right.sequence));
    while (_active < maxActive && _pending.isNotEmpty) {
      final pending = _pending.removeAt(0);
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_start());
      }
    }
  }
}

final class StorageWriteLease {
  StorageWriteLease._(this._release);

  final void Function() _release;

  void release() => _release();
}

final class _PendingStorageWrite {
  const _PendingStorageWrite({
    required this.sequence,
    required this.completer,
    required this.control,
  });

  final int sequence;
  final Completer<StorageWriteLease> completer;
  final TaskControl? control;
}
