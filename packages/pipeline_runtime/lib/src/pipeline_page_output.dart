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

/// Receives visual projection changes for a page output.
///
/// A platform texture may replace its resident contents for every animation
/// frame while retaining the same [PipelinePageSurface.presentationIdentity].
/// Those presentation-only snapshots remain available through
/// [PipelinePageOutputStream.snapshot], but do not require a listener callback
/// or a Flutter subtree update. If one arrives while a Flutter frame is
/// already queued or inside persistent callbacks, the output stream submits
/// only the latest frame after that frame so page composition retains
/// priority.
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
    void Function()? onPlaybackWakeChanged,
  })  : _uploads = uploads,
        _decodes = decodes,
        _outputs = outputs,
        _frameScheduler = frameScheduler,
        _onPlaybackWakeChanged = onPlaybackWakeChanged,
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
  final void Function()? _onPlaybackWakeChanged;
  final Set<PipelinePageOutputListener> _listeners =
      <PipelinePageOutputListener>{};
  final Set<PresentClaim> _deferredClaims = <PresentClaim>{};
  bool _deferredClaimReleaseScheduled = false;
  bool _presentationAfterFrameScheduled = false;
  bool _detachedPrewarmEnabled = false;
  bool _detachedPrewarmActive = false;

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

  // Detached output streams are retained only while they still own a
  // projection or a listener. The Reader may recreate a stream when a page
  // re-enters the viewport, so an empty stream can be pruned without changing
  // page/output identity or playback state.
  bool get _isEmptyDetachedStream =>
      _listeners.isEmpty &&
      _identity == null &&
      !_snapshot.hasSurface &&
      _claim == null;

  void addListener(
    PipelinePageOutputListener listener, {
    bool fireImmediately = true,
  }) {
    _requireOpen();
    // A page host is now the visible owner of this output. It must catch up
    // to the latest upload snapshot after receiving the immediate projection;
    // otherwise a detached gallery prewarm could leave the host on frame zero
    // until the next playback tick.
    _detachedPrewarmActive = false;
    _listeners.add(listener);
    if (fireImmediately) {
      listener(_snapshot);
    }
    final identity = _identity;
    final latest = identity == null ? null : _uploads.find(identity)?.snapshot;
    if (identity != null &&
        latest != null &&
        latest.state == UploadState.ready &&
        latest.frameIndex != _snapshot.frameIndex) {
      _accept(identity, latest);
    }
  }

  void removeListener(PipelinePageOutputListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty && _detachedPrewarmEnabled) {
      _detachedPrewarmActive = true;
    }
    if (!_disposed && _listeners.isEmpty && _identity == null) {
      _clearProjection(PipelinePageOutputState.idle);
    }
  }

  /// Allows the Pipeline to present the first planned gallery frame before a
  /// PageView host is mounted. This is deliberately a presentation-only
  /// optimization: it does not create demand or alter playback/freeze state.
  /// Once a host attaches, normal successor presentation resumes immediately.
  void _enableDetachedPrewarm() {
    _detachedPrewarmEnabled = true;
    if (_listeners.isEmpty) {
      _detachedPrewarmActive = true;
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
    _presentationAfterFrameScheduled = false;
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
        if (_detachedPrewarmActive &&
            _listeners.isEmpty &&
            _presentationOnlyUpdate(identity, upload)) {
          // A detached gallery page only needs one resident frame so its
          // SurfaceProducer is ready when the PageView mounts. Keep decoding
          // and the playback timer untouched, but do not spend the platform
          // blit lane presenting invisible successors.
          return;
        }
        // A detached first frame has no visible host to compete with the
        // current Flutter composition. Let its platform resident surface be
        // ready before PageView mounts; only successor updates below yield to
        // an already scheduled UI frame.
        final frameBeforePostFrame =
            _frameScheduler.inPersistentCallbacks ||
            _frameScheduler.hasScheduledFrame;
        // During a post-frame callback, requestFrame() has already queued the
        // next frame; the post-frame boundary itself is the safe handoff and
        // must not recursively defer this same successor. Treat a scheduled
        // frame as a pre-frame signal in every phase before post-frame
        // callbacks, including transient callbacks driven by PageView's
        // scroll animation. The adapter masks a frame requested from a
        // post-frame callback, so this remains a one-frame handoff rather than
        // recursively scheduling the same successor forever.
        if (_presentationOnlyUpdate(identity, upload) &&
            frameBeforePostFrame) {
          // A successor of an already visible animated output is not needed
          // to compose the current or already queued Flutter frame. Starting
          // a platform presentation from the pre-frame/persistent window
          // competes with PageView layout/paint and can make that UI frame
          // miss its deadline. Keep only the latest decoded/uploaded frame and
          // submit it after this frame. The playback timer remains untouched;
          // only the presentation boundary yields to UI work.
          _presentationPending = true;
          _schedulePresentationAfterFrame(identity);
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

  bool _presentationOnlyUpdate(DecodeId identity, UploadSnapshot upload) {
    return _snapshot.state == PipelinePageOutputState.ready &&
        _snapshot.hasSurface &&
        !_snapshot.replacing &&
        (_snapshot.isAnimated ||
            (_snapshot.duration?.inMicroseconds ?? 0) > 0) &&
        _surfaceIdentity == identity &&
        upload.frameIndex != null &&
        upload.frameIndex != _snapshot.frameIndex;
  }

  void _schedulePresentationAfterFrame(DecodeId identity) {
    if (_presentationAfterFrameScheduled) return;
    _presentationAfterFrameScheduled = true;
    final generation = _generation;
    _frameScheduler.afterFrame(() {
      if (generation == _generation) {
        _presentationAfterFrameScheduled = false;
      }
      if (_disposed || generation != _generation || _identity != identity) {
        return;
      }
      final latest = _uploads.find(identity)?.snapshot;
      _presentationPending = false;
      if (latest == null ||
          latest.state != UploadState.ready ||
          latest.frameIndex == _snapshot.frameIndex) {
        return;
      }
      _accept(identity, latest);
    });
    _requestAfterFrameCallbackFrame();
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
      final reusedStatic = _uploads.reusePresentedStatic(identity, claim);
      if (!reusedStatic) {
        await _uploads.present(identity, claim);
      }
      if (_disposed ||
          generation != _generation ||
          _identity != identity) {
        claim.release();
        return;
      }
      if (claim.frame.duration.inMicroseconds > 0) {
        // UploadSession arms the per-output deadline before this future
        // completes. Rebuild the Reader's single global wake only after the
        // real presentation boundary, instead of scanning every upload from
        // the pre-presentation ready callback on each animation tick.
        _onPlaybackWakeChanged?.call();
      }
      final surface = _outputs.project(claim.frame);
      final animation = _decodes.find(identity)?.snapshot.animation ??
          const AnimationInfo.unknown();
      final prior = _claim;
      _claim = claim;
      _surfaceIdentity = identity;
      final next = PipelinePageOutputSnapshot(
        state: PipelinePageOutputState.ready,
        surface: surface,
        frameIndex: claim.frame.index,
        duration: claim.frame.duration,
        animation: animation,
        replacing: false,
        failure: null,
      );
      final presentationOnly = _isPresentationOnlyUpdate(_snapshot, next);
      _publish(next);
      if (presentationOnly) {
        // The platform present has already copied the frame into the same
        // resident SurfaceProducer target. No Flutter subtree retains the
        // previous OutputFrame, so releasing its claim now avoids scheduling
        // an otherwise idle Flutter frame for every animation tick. A
        // changed surface/lease/fallback still uses the post-frame drain
        // below to protect the old visual projection.
        prior?.release();
      } else {
        _releaseAfterVisualSwap(prior);
      }
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
    _presentationAfterFrameScheduled = false;
    _detachedPrewarmActive = false;
    _detachedPrewarmEnabled = false;
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
    if (_deferredClaimReleaseScheduled) {
      return;
    }
    _deferredClaimReleaseScheduled = true;
    _frameScheduler.afterFrame(() {
      _deferredClaimReleaseScheduled = false;
      final claims = _deferredClaims.toList(growable: false);
      _deferredClaims.clear();
      for (final deferred in claims) {
        deferred.release();
      }
    });
    _requestAfterFrameCallbackFrame();
  }

  void _requestAfterFrameCallbackFrame() {
    // addPostFrameCallback only needs an additional frame when there is no
    // frame already in flight. During persistent callbacks the current frame
    // will naturally drain the callback; while a frame is queued, scheduling
    // another one only adds an idle UI turn for an animation presentation.
    if (_frameScheduler.inPersistentCallbacks ||
        _frameScheduler.hasScheduledFrame) {
      return;
    }
    _frameScheduler.requestFrame();
  }

  void _publish(PipelinePageOutputSnapshot snapshot) {
    final prior = _snapshot;
    _snapshot = snapshot;
    if (_isPresentationOnlyUpdate(prior, snapshot)) {
      return;
    }
    for (final listener in _listeners.toList(growable: false)) {
      listener(snapshot);
    }
  }

  bool _isPresentationOnlyUpdate(
    PipelinePageOutputSnapshot prior,
    PipelinePageOutputSnapshot next,
  ) {
    final priorSurface = prior.surface;
    final nextSurface = next.surface;
    return prior.state == PipelinePageOutputState.ready &&
        next.state == PipelinePageOutputState.ready &&
        !prior.replacing &&
        !next.replacing &&
        identical(prior.failure, next.failure) &&
        prior.animation == next.animation &&
        priorSurface != null &&
        nextSurface != null &&
        identical(
          priorSurface.presentationIdentity,
          nextSurface.presentationIdentity,
        ) &&
        priorSurface.width == nextSurface.width &&
        priorSurface.height == nextSurface.height;
  }

  void _requireOpen() {
    if (_disposed) {
      throw StateError('pipeline page output stream is disposed');
    }
  }
}
