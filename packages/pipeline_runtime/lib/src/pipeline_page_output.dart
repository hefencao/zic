part of 'pipeline_reader_session.dart';

enum PipelinePageOutputState { idle, preparing, ready, failed, disposed }

final class PipelinePageOutputSnapshot {
  const PipelinePageOutputSnapshot({
    required this.state,
    required this.surface,
    required this.frameIndex,
    required this.duration,
    required this.animation,
    required this.replacing,
    required this.failure,
  });

  final PipelinePageOutputState state;
  final PipelinePageSurface? surface;
  final int? frameIndex;
  final Duration? duration;
  final AnimationInfo animation;
  final bool replacing;
  final Failure? failure;

  bool get hasSurface => surface != null;
  bool get isAnimated => animation.frameCount > 1;
}

typedef PipelinePageOutputListener = void Function(
  PipelinePageOutputSnapshot snapshot,
);

/// Read-only projection of one Pipeline-owned page output.
///
/// Mutation methods are library-private. Presentation cannot claim, present,
/// advance or dispose the underlying upload frame or platform surface.
final class PipelinePageOutputStream {
  PipelinePageOutputStream._({
    required this.download,
    required UploadRegistry uploads,
    required DecodeRegistry decodes,
    required PipelineOutputProjector outputs,
    required PipelineFrameScheduler frameScheduler,
  })  : _uploads = uploads,
        _decodes = decodes,
        _outputs = outputs,
        _frameScheduler = frameScheduler,
        _snapshot = PipelinePageOutputSnapshot(
          state: PipelinePageOutputState.idle,
          surface: null,
          frameIndex: null,
          duration: null,
          animation: const AnimationInfo.unknown(),
          replacing: false,
          failure: null,
        );

  final DownloadId download;
  final UploadRegistry _uploads;
  final DecodeRegistry _decodes;
  final PipelineOutputProjector _outputs;
  final PipelineFrameScheduler _frameScheduler;
  final Set<PipelinePageOutputListener> _listeners =
      <PipelinePageOutputListener>{};
  final Set<PresentClaim> _deferredClaims = <PresentClaim>{};

  PipelinePageOutputSnapshot _snapshot;
  DecodeId? _identity;
  DecodeId? _surfaceIdentity;
  PresentClaim? _claim;
  DecodeId? _presentingIdentity;
  int? _presentingFrameIndex;
  bool _presentationPending = false;
  int _generation = 0;
  bool _disposed = false;

  PipelinePageOutputSnapshot get snapshot => _snapshot;

  void addListener(
    PipelinePageOutputListener listener, {
    bool fireImmediately = true,
  }) {
    _requireOpen();
    _listeners.add(listener);
    if (fireImmediately) {
      listener(_snapshot);
    }
  }

  void removeListener(PipelinePageOutputListener listener) {
    _listeners.remove(listener);
    if (!_disposed && _listeners.isEmpty && _identity == null) {
      _clearProjection(PipelinePageOutputState.idle);
    }
  }

  bool get _hasAuthoritativeStaticProjection =>
      _snapshot.hasSurface &&
      (_snapshot.duration?.inMicroseconds ?? -1) <= 0 &&
      _snapshot.animation.complete &&
      _snapshot.animation.frameCount <= 1 &&
      _surfaceIdentity != null;

  void _bind(
    DecodeId? identity, {
    DecodeId? retainedStaticIdentity,
  }) {
    _requireOpen();
    if (_identity == identity) {
      if (identity == null) {
        _retainOrClearDetachedStaticProjection(retainedStaticIdentity);
      }
      return;
    }
    _identity = identity;
    _generation++;
    _presentingIdentity = null;
    _presentingFrameIndex = null;
    _presentationPending = false;
    if (identity == null) {
      _retainOrClearDetachedStaticProjection(retainedStaticIdentity);
      return;
    }

    final alreadyProjected = _surfaceIdentity == identity &&
        _hasAuthoritativeStaticProjection &&
        _listeners.isNotEmpty;
    final prior = _snapshot;
    _publish(
      PipelinePageOutputSnapshot(
        state: prior.hasSurface
            ? PipelinePageOutputState.ready
            : PipelinePageOutputState.preparing,
        surface: prior.surface,
        frameIndex: prior.frameIndex,
        duration: prior.duration,
        animation: prior.animation,
        replacing: prior.hasSurface && !alreadyProjected,
        failure: null,
      ),
    );
    final upload = _uploads.find(identity)?.snapshot;
    if (upload != null) {
      _accept(identity, upload);
    }
  }

  void _retainOrClearDetachedStaticProjection(
    DecodeId? retainedStaticIdentity,
  ) {
    final mayRetain = _listeners.isNotEmpty &&
        retainedStaticIdentity != null &&
        _surfaceIdentity == retainedStaticIdentity &&
        _hasAuthoritativeStaticProjection;
    if (mayRetain) {
      if (_snapshot.replacing ||
          _snapshot.state != PipelinePageOutputState.ready) {
        _publish(
          PipelinePageOutputSnapshot(
            state: PipelinePageOutputState.ready,
            surface: _snapshot.surface,
            frameIndex: _snapshot.frameIndex,
            duration: _snapshot.duration,
            animation: _snapshot.animation,
            replacing: false,
            failure: _snapshot.failure,
          ),
        );
      }
      return;
    }
    _clearProjection(PipelinePageOutputState.idle);
  }

  void _clearProjection(PipelinePageOutputState state) {
    if (!_snapshot.hasSurface && _claim == null && _surfaceIdentity == null) {
      if (_snapshot.state != state) {
        _publish(
          PipelinePageOutputSnapshot(
            state: state,
            surface: null,
            frameIndex: null,
            duration: null,
            animation: const AnimationInfo.unknown(),
            replacing: false,
            failure: null,
          ),
        );
      }
      return;
    }
    final prior = _takeClaim();
    _surfaceIdentity = null;
    _publish(
      PipelinePageOutputSnapshot(
        state: state,
        surface: null,
        frameIndex: null,
        duration: null,
        animation: const AnimationInfo.unknown(),
        replacing: false,
        failure: null,
      ),
    );
    _releaseAfterVisualSwap(prior);
  }

  void _accept(DecodeId identity, UploadSnapshot upload) {
    if (_disposed || _identity != identity) {
      return;
    }
    switch (upload.state) {
      case UploadState.ready:
        final replacementFailure = upload.failure;
        if (replacementFailure != null &&
            _snapshot.hasSurface &&
            _snapshot.frameIndex == upload.frameIndex) {
          _publish(
            PipelinePageOutputSnapshot(
              state: PipelinePageOutputState.ready,
              surface: _snapshot.surface,
              frameIndex: _snapshot.frameIndex,
              duration: _snapshot.duration,
              animation: _snapshot.animation,
              replacing: false,
              failure: replacementFailure,
            ),
          );
        }
        if (_presentingIdentity == identity) {
          if (_presentingFrameIndex != upload.frameIndex) {
            _presentationPending = true;
          }
          return;
        }
        unawaited(_present(identity, upload));
      case UploadState.failed:
        final failure = upload.failure ??
            const Failure(
              code: ErrorCode.texture,
              message: 'pipeline page upload failed',
            );
        if (_snapshot.hasSurface) {
          _publish(
            PipelinePageOutputSnapshot(
              state: PipelinePageOutputState.ready,
              surface: _snapshot.surface,
              frameIndex: _snapshot.frameIndex,
              duration: _snapshot.duration,
              animation: _snapshot.animation,
              replacing: false,
              failure: failure,
            ),
          );
        } else {
          _publish(
            PipelinePageOutputSnapshot(
              state: PipelinePageOutputState.failed,
              surface: null,
              frameIndex: null,
              duration: null,
              animation: const AnimationInfo.unknown(),
              replacing: false,
              failure: failure,
            ),
          );
        }
      case UploadState.idle:
      case UploadState.waitingFrame:
      case UploadState.uploading:
        if (!_snapshot.hasSurface) {
          _publish(
            PipelinePageOutputSnapshot(
              state: PipelinePageOutputState.preparing,
              surface: null,
              frameIndex: null,
              duration: null,
              animation: const AnimationInfo.unknown(),
              replacing: false,
              failure: null,
            ),
          );
        }
      case UploadState.disposed:
        _surfaceIdentity = null;
        final prior = _takeClaim();
        _publish(
          PipelinePageOutputSnapshot(
            state: PipelinePageOutputState.disposed,
            surface: null,
            frameIndex: null,
            duration: null,
            animation: const AnimationInfo.unknown(),
            replacing: false,
            failure: null,
          ),
        );
        _releaseAfterVisualSwap(prior);
    }
  }

  Future<void> _present(DecodeId identity, UploadSnapshot upload) async {
    if ((_snapshot.frameIndex == upload.frameIndex &&
            _identity == identity &&
            !_snapshot.replacing) ||
        (_presentingIdentity == identity &&
            _presentingFrameIndex == upload.frameIndex)) {
      return;
    }
    final generation = _generation;
    _presentingIdentity = identity;
    _presentingFrameIndex = upload.frameIndex;
    final claim = _uploads.claimPresent(identity);
    if (claim == null) {
      _finishPresentation(
        identity: identity,
        frameIndex: upload.frameIndex,
        generation: generation,
      );
      return;
    }
    try {
      await _uploads.present(identity, claim);
      if (_disposed ||
          generation != _generation ||
          _identity != identity) {
        claim.release();
        return;
      }
      final surface = _outputs.project(claim.frame);
      final animation = _decodes.find(identity)?.snapshot.animation ??
          const AnimationInfo.unknown();
      final prior = _claim;
      _claim = claim;
      _surfaceIdentity = identity;
      _publish(
        PipelinePageOutputSnapshot(
          state: PipelinePageOutputState.ready,
          surface: surface,
          frameIndex: claim.frame.index,
          duration: claim.frame.duration,
          animation: animation,
          replacing: false,
          failure: null,
        ),
      );
      _releaseAfterVisualSwap(prior);
    } on Object catch (error) {
      claim.release();
      if (_disposed || generation != _generation || _identity != identity) {
        return;
      }
      final failure = error is Failure
          ? error
          : Failure(
              code: ErrorCode.texture,
              message: 'pipeline page presentation failed',
              cause: error,
            );
      if (_snapshot.hasSurface) {
        _publish(
          PipelinePageOutputSnapshot(
            state: PipelinePageOutputState.ready,
            surface: _snapshot.surface,
            frameIndex: _snapshot.frameIndex,
            duration: _snapshot.duration,
            animation: _snapshot.animation,
            replacing: false,
            failure: failure,
          ),
        );
      } else {
        _publish(
          PipelinePageOutputSnapshot(
            state: PipelinePageOutputState.failed,
            surface: null,
            frameIndex: null,
            duration: null,
            animation: const AnimationInfo.unknown(),
            replacing: false,
            failure: failure,
          ),
        );
      }
    } finally {
      _finishPresentation(
        identity: identity,
        frameIndex: upload.frameIndex,
        generation: generation,
      );
    }
  }

  void _finishPresentation({
    required DecodeId identity,
    required int? frameIndex,
    required int generation,
  }) {
    if (generation != _generation ||
        _presentingIdentity != identity ||
        _presentingFrameIndex != frameIndex) {
      return;
    }
    _presentingIdentity = null;
    _presentingFrameIndex = null;
    final presentLatest = _presentationPending;
    _presentationPending = false;
    if (!presentLatest || _disposed || _identity != identity) {
      return;
    }
    final latest = _uploads.find(identity)?.snapshot;
    if (latest == null ||
        latest.state != UploadState.ready ||
        latest.frameIndex == _snapshot.frameIndex) {
      return;
    }
    scheduleMicrotask(() {
      if (!_disposed && _identity == identity) {
        _accept(identity, latest);
      }
    });
  }

  void _dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _presentingIdentity = null;
    _presentingFrameIndex = null;
    _presentationPending = false;
    _surfaceIdentity = null;
    _releaseClaim();
    for (final claim in _deferredClaims.toList(growable: false)) {
      claim.release();
    }
    _deferredClaims.clear();
    _snapshot = PipelinePageOutputSnapshot(
      state: PipelinePageOutputState.disposed,
      surface: null,
      frameIndex: null,
      duration: null,
      animation: const AnimationInfo.unknown(),
      replacing: false,
      failure: null,
    );
    for (final listener in _listeners.toList(growable: false)) {
      listener(_snapshot);
    }
    _listeners.clear();
  }

  PresentClaim? _takeClaim() {
    final claim = _claim;
    _claim = null;
    return claim;
  }

  void _releaseClaim() => _takeClaim()?.release();

  void _releaseAfterVisualSwap(PresentClaim? claim) {
    if (claim == null) {
      return;
    }
    if (_listeners.isEmpty) {
      claim.release();
      return;
    }
    _deferredClaims.add(claim);
    _frameScheduler.afterFrame(() {
      if (_deferredClaims.remove(claim)) {
        claim.release();
      }
    });
    _frameScheduler.requestFrame();
  }

  void _publish(PipelinePageOutputSnapshot snapshot) {
    _snapshot = snapshot;
    for (final listener in _listeners.toList(growable: false)) {
      listener(snapshot);
    }
  }

  void _requireOpen() {
    if (_disposed) {
      throw StateError('pipeline page output stream is disposed');
    }
  }
}
