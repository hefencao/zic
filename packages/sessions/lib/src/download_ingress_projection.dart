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

  IngressSnap get snapshot => ingress.snapshot;
  EncodedSource? get source => ingress.source;

  void addSourceListener(
    SourceListener listener, {
    bool fireImmediately = true,
  }) {
    _listeners.add(listener);
    final current = ingress.snapshot;
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
    final before = ingress.snapshot;
    ingress.reset(epoch);
    _notify(before, ingress.snapshot);
  }

  void append({
    required SourceEpoch epoch,
    required int offset,
    required List<int> bytes,
  }) {
    final before = ingress.snapshot;
    ingress.append(epoch: epoch, offset: offset, bytes: bytes);
    _notify(before, ingress.snapshot);
  }

  void seal(SourceEpoch epoch) {
    final before = ingress.snapshot;
    ingress.seal(epoch);
    _notify(before, ingress.snapshot);
  }

  Future<void> rebuild({
    required SourceEpoch epoch,
    required Stream<List<int>> chunks,
    required bool sealed,
  }) async {
    final before = ingress.snapshot;
    await ingress.rebuild(epoch: epoch, chunks: chunks, sealed: sealed);
    _notify(before, ingress.snapshot);
  }

  void fail(Failure failure) {
    final before = ingress.snapshot;
    ingress.fail(failure);
    _notify(before, ingress.snapshot);
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
