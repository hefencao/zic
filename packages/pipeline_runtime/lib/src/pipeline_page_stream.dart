import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:transport/transport.dart' show ContentKind;

/// Presentation-safe transfer projection for one Pipeline-owned logical page.
///
/// The logical [identity] is stable across presentation rebuilds, while the
/// bound physical [DownloadSession] is selected only after transfer demand
/// reconciliation has had a chance to resolve verified-equivalent aliases.
/// EncodedSource, cursor, artifact and session objects never cross this
/// boundary. WebP rendering is exposed separately through
/// PipelinePageOutputStream.
enum PipelinePageTransferState {
  idle,
  queued,
  receiving,
  sealed,
  promoted,
  failed,
  disposed,
}

/// Presentation-safe content classification.
///
/// The pipeline maps transport sniffing into this enum so Reader/media
/// consumers do not depend on transport-layer types.
enum PipelinePageContentKind { unknown, webp, gif, fallback }

final class PipelinePageStreamSnapshot {
  const PipelinePageStreamSnapshot({
    required this.state,
    required this.committedLength,
    required this.totalLength,
    required this.kind,
    required this.sourceCanvasWidth,
    required this.sourceCanvasHeight,
    required this.failure,
  });

  final PipelinePageTransferState state;
  final int committedLength;
  final int? totalLength;
  final PipelinePageContentKind? kind;

  /// Encoded-media canvas dimensions owned by the bound physical generation.
  ///
  /// Presentation may use these dimensions as source-aspect authority, but it
  /// must not infer them from the decoded raster because native scaling can
  /// round width/height independently by a few physical pixels.
  final int? sourceCanvasWidth;
  final int? sourceCanvasHeight;
  final Failure? failure;
}

typedef PipelinePageStreamListener = void Function(
  PipelinePageStreamSnapshot snapshot,
);

final class PipelinePageStream {
  PipelinePageStream.forDownload(
    this.identity, {
    required DownloadSession? Function() resolvePhysical,
    DownloadResidentReplaySource? residentReplaySource,
  })  : _resolvePhysical = resolvePhysical,
        _residentReplaySource = residentReplaySource;

  final DownloadId identity;
  final DownloadSession? Function() _resolvePhysical;
  final DownloadResidentReplaySource? _residentReplaySource;
  DownloadSession? _session;
  final Set<PipelinePageStreamListener> _listeners =
      <PipelinePageStreamListener>{};

  static const PipelinePageStreamSnapshot _idle = PipelinePageStreamSnapshot(
    state: PipelinePageTransferState.idle,
    committedLength: 0,
    totalLength: null,
    kind: null,
    sourceCanvasWidth: null,
    sourceCanvasHeight: null,
    failure: null,
  );

  PipelinePageStreamSnapshot get snapshot {
    final session = _session;
    return session == null ? _idle : _project(session.snapshot);
  }

  int get committedLength => _session?.committedLength ?? 0;
  PipelinePageTransferState get state {
    final session = _session;
    return session == null
        ? PipelinePageTransferState.idle
        : _state(session.state);
  }

  Future<Uint8List> readPrefix(int maxBytes) async {
    final session = _session;
    if (session == null || maxBytes <= 0) return Uint8List(0);
    // This stream can rebind to a replacement physical generation. Keep the
    // cross-owner replay service unbound until the current session is known,
    // then pass DownloadSession only a generation-bound `(end) => chunks`
    // capability.
    final replaySource = _residentReplaySource;
    return session.readSourcePrefix(
      maxBytes,
      residentReplayChunks: replaySource == null
          ? null
          : (endExclusive) => replaySource(session, endExclusive),
    );
  }

  void addListener(
    PipelinePageStreamListener listener, {
    bool fireImmediately = true,
  }) {
    if (!_listeners.add(listener)) return;
    if (_listeners.length == 1) {
      _session?.addSnapshotListener(
        _handleSessionSnapshot,
        fireImmediately: false,
      );
    }
    if (fireImmediately) listener(snapshot);
  }

  void removeListener(PipelinePageStreamListener listener) {
    if (!_listeners.remove(listener)) return;
    if (_listeners.isEmpty) {
      _session?.removeSnapshotListener(_handleSessionSnapshot);
    }
  }

  /// Rebinds this logical projection to the already-resolved physical owner.
  ///
  /// This method deliberately accepts `null`: presentation may exist before a
  /// transfer demand is reconciled, but that must never create a physical
  /// session as a side effect. A later observation binds the same logical
  /// projection to whichever physical session the transfer owner selected.
  void refreshBinding() {
    final session = _resolvePhysical();
    if (identical(_session, session)) return;
    final observing = _listeners.isNotEmpty;
    if (observing) {
      _session?.removeSnapshotListener(_handleSessionSnapshot);
    }
    _session = session;
    if (observing) {
      session?.addSnapshotListener(
        _handleSessionSnapshot,
        fireImmediately: false,
      );
      _broadcast(snapshot);
    }
  }

  void dispose() {
    if (_listeners.isNotEmpty) {
      _session?.removeSnapshotListener(_handleSessionSnapshot);
    }
    _listeners.clear();
    _session = null;
  }

  void _handleSessionSnapshot(DownloadSnapshot snapshot) =>
      _broadcast(_project(snapshot));

  void _broadcast(PipelinePageStreamSnapshot snapshot) {
    for (final listener in _listeners.toList(growable: false)) {
      listener(snapshot);
    }
  }

  static PipelinePageStreamSnapshot _project(DownloadSnapshot snapshot) =>
      PipelinePageStreamSnapshot(
        state: _state(snapshot.state),
        committedLength: snapshot.committedLength,
        totalLength: snapshot.totalLength,
        kind: _contentKind(snapshot.contentKind),
        sourceCanvasWidth: snapshot.sourceCanvasWidth,
        sourceCanvasHeight: snapshot.sourceCanvasHeight,
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

PipelinePageContentKind? _contentKind(ContentKind? kind) => switch (kind) {
      null => null,
      ContentKind.unknown => PipelinePageContentKind.unknown,
      ContentKind.webp => PipelinePageContentKind.webp,
      ContentKind.gif => PipelinePageContentKind.gif,
      ContentKind.fallback => PipelinePageContentKind.fallback,
    };
