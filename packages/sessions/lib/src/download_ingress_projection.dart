import 'package:domain/domain.dart';
import 'package:media/media.dart';

typedef SourceListener = void Function(IngressSnap snapshot);

/// Reader-local projection of one physical [DownloadSession] into a native
/// encoded source.
///
/// The physical download owns artifact bytes, writer/run state and network
/// resume metadata. This projection owns only one consumer's [Ingress] and its
/// source listeners. Multiple projections may attach to the same physical
/// download without sharing decode/upload state.
final class DownloadIngressProjection {
  DownloadIngressProjection({
    required this.scopeId,
    required this.ingress,
  }) {
    if (scopeId.isEmpty) {
      throw ArgumentError.value(scopeId, 'scopeId', 'must not be empty');
    }
  }

  final String scopeId;
  final Ingress ingress;
  final Set<SourceListener> _listeners = <SourceListener>{};
  bool _synchronizedReplayPending = false;

  IngressSnap get snapshot {
    final current = ingress.snapshot;
    if (!_synchronizedReplayPending) return current;
    return IngressSnap(
      epoch: current.epoch,
      length: current.length,
      kind: current.kind,
      sealed: current.sealed,
      sourceReady: false,
      revision: current.revision,
      failure: current.failure,
    );
  }

  EncodedSource? get source =>
      _synchronizedReplayPending ? null : ingress.source;

  /// Hides a late-join source while an authoritative physical prefix is being
  /// replayed into it. Decode must not bind to an intermediate source that may
  /// still need a same-epoch catch-up or rebuild before physical attachment.
  void beginSynchronizedReplay() {
    _synchronizedReplayPending = true;
  }

  /// Publishes the replayed source. A late-join caller may invoke this after a
  /// decoder-usable prefix is locally replayed, then continue same-source
  /// suffix catch-up before joining the physical live fan-out. The physical
  /// owner remains responsible for proving a stable boundary before fan-out.
  void publishSynchronizedReplayPrefix() {
    if (!_synchronizedReplayPending) return;
    final before = snapshot;
    _synchronizedReplayPending = false;
    _notify(before, snapshot);
  }

  void finishSynchronizedReplay() {
    publishSynchronizedReplayPrefix();
  }

  void addSourceListener(
    SourceListener listener, {
    bool fireImmediately = true,
  }) {
    _listeners.add(listener);
    final current = snapshot;
    if (fireImmediately &&
        (current.sourceReady || current.failure != null)) {
      try {
        listener(current);
      } on Object {
        // Consumer observers must not break the native ingress projection.
      }
    }
  }

  void removeSourceListener(SourceListener listener) {
    _listeners.remove(listener);
  }

  void expectLength(int? length) {
    ingress.expectLength(length);
  }

  void reset(SourceEpoch epoch) {
    final before = snapshot;
    ingress.reset(epoch);
    _notify(before, snapshot);
  }

  void append({
    required SourceEpoch epoch,
    required int offset,
    required List<int> bytes,
  }) {
    final before = snapshot;
    ingress.append(epoch: epoch, offset: offset, bytes: bytes);
    _notify(before, snapshot);
  }

  void seal(SourceEpoch epoch) {
    final before = snapshot;
    ingress.seal(epoch);
    _notify(before, snapshot);
  }

  Future<void> rebuild({
    required SourceEpoch epoch,
    required Stream<List<int>> chunks,
    required bool sealed,
  }) async {
    final before = snapshot;
    await ingress.rebuild(epoch: epoch, chunks: chunks, sealed: sealed);
    _notify(before, snapshot);
  }

  void fail(Failure failure) {
    final before = snapshot;
    ingress.fail(failure);
    _synchronizedReplayPending = false;
    _notify(before, snapshot);
  }

  void detach() {
    _listeners.clear();
  }

  void _notify(IngressSnap before, IngressSnap after) {
    final changed =
        before.revision != after.revision ||
        before.length != after.length ||
        before.sealed != after.sealed ||
        before.kind != after.kind ||
        before.sourceReady != after.sourceReady ||
        before.failure != after.failure;
    if (!changed) return;
    for (final listener in List<SourceListener>.of(_listeners)) {
      try {
        listener(after);
      } on Object {
        // Consumer observers must not break the native ingress projection.
      }
    }
  }
}
