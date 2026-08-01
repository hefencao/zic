import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';

/// Presentation-safe projection of one pipeline-owned encoded-byte session.
///
/// Reader/media widgets can observe committed bytes and attach a streaming
/// decoder, but they cannot enqueue, retry, cancel, promote or otherwise
/// mutate the underlying DownloadSession.
enum PipelinePageTransferState {
  idle,
  queued,
  receiving,
  sealed,
  promoted,
  failed,
  disposed,
}

final class PipelinePageStreamSnapshot {
  const PipelinePageStreamSnapshot({
    required this.state,
    required this.committedLength,
    required this.totalLength,
    required this.kind,
    required this.source,
    required this.failure,
  });

  final PipelinePageTransferState state;
  final int committedLength;
  final int? totalLength;
  final ContentKind? kind;
  final EncodedSource? source;
  final Failure? failure;
}

typedef PipelinePageStreamListener = void Function(
  PipelinePageStreamSnapshot snapshot,
);

final class PipelinePageStream {
  PipelinePageStream._(this._session);

  final DownloadSession _session;
  final Map<PipelinePageStreamListener, DownloadSnapshotListener> _listeners =
      <PipelinePageStreamListener, DownloadSnapshotListener>{};

  static PipelinePageStream fromSession(DownloadSession session) =>
      PipelinePageStream._(session);

  PipelinePageStreamSnapshot get snapshot => _project(_session.snapshot);
  int get committedLength => _session.committedLength;
  PipelinePageTransferState get state => _state(_session.state);
  EncodedSource? get source => _session.ingress?.source;
  DownloadId get identity => _session.id;

  Future<Uint8List> readPrefix(int maxBytes) async =>
      Uint8List.fromList(await _session.artifact.readPrefix(maxBytes));

  void addListener(
    PipelinePageStreamListener listener, {
    bool fireImmediately = true,
  }) {
    if (_listeners.containsKey(listener)) return;
    void wrapped(DownloadSnapshot snapshot) => listener(_project(snapshot));
    _listeners[listener] = wrapped;
    _session.addSnapshotListener(wrapped, fireImmediately: fireImmediately);
  }

  void removeListener(PipelinePageStreamListener listener) {
    final wrapped = _listeners.remove(listener);
    if (wrapped != null) _session.removeSnapshotListener(wrapped);
  }

  PipelinePageStreamSnapshot _project(DownloadSnapshot snapshot) =>
      PipelinePageStreamSnapshot(
        state: _state(snapshot.state),
        committedLength: snapshot.committedLength,
        totalLength: snapshot.totalLength,
        kind: snapshot.ingress?.kind,
        source: snapshot.ingress?.source,
        failure: snapshot.failure,
      );
}

PipelinePageTransferState _state(DownloadState state) => switch (state) {
      DownloadState.idle => PipelinePageTransferState.idle,
      DownloadState.queued => PipelinePageTransferState.queued,
      DownloadState.receiving => PipelinePageTransferState.receiving,
      DownloadState.sealed => PipelinePageTransferState.sealed,
      DownloadState.promoted => PipelinePageTransferState.promoted,
      DownloadState.failed => PipelinePageTransferState.failed,
      DownloadState.disposed => PipelinePageTransferState.disposed,
    };
