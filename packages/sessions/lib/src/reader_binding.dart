import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'coordinator.dart';

/// Connects reader observations to demand reconciliation and viewport playback.
///
/// The reader remains unaware of pipeline/session lifecycles. This binding is
/// the application-layer composition point for one reading session.
final class ReaderBinding {
  ReaderBinding({
    required this.chapter,
    required DecodeTarget decodeTarget,
    required MonoClock clock,
    required Coordinator coordinator,
    required PlaybackCoordinator playback,
    TraceSink traceSink = const NoopTraceSink(),
    ViewportResolver viewportResolver = const ViewportResolver(),
    RoleResolver windowResolver = const RoleResolver(),
    HeuristicPolicy policy = const HeuristicPolicy(),
    PolicyGuard policyGuard = const PolicyGuard(),
    this.discretePages = true,
  })  : _coordinator = coordinator,
        _playback = playback,
        _viewportResolver = viewportResolver,
        _pageIndexes = <String, int>{
          for (final page in chapter.pages) page.pageId: page.index,
        } {
    pipeline = PipelineController(
      chapter: chapter,
      decodeTarget: decodeTarget,
      clock: clock,
      traceSink: traceSink,
      windowResolver: windowResolver,
      policy: policy,
      guard: policyGuard,
      onUpdate: _onUpdate,
    );
  }

  final ChapterManifest chapter;
  final bool discretePages;
  final Coordinator _coordinator;
  final PlaybackCoordinator _playback;
  final ViewportResolver _viewportResolver;
  final Map<String, int> _pageIndexes;
  late final PipelineController pipeline;

  ReaderObs? _observation;
  ViewportState? _viewport;
  ViewportState? _playbackViewport;
  int? _playbackPlanRevision;
  int? _cachedUploadRevision;
  Map<int, DecodeId> _cachedUploadIds = const <int, DecodeId>{};
  bool _detached = false;

  ViewportState? get viewport => _viewport;
  int get revision => pipeline.revision;

  void accept(ReaderObs observation) {
    if (_detached) {
      throw StateError('reader binding is detached');
    }
    _observation = observation;
    final viewport = _viewportResolver.resolve(
      observation,
      // Vertical Reader is continuous presentation. Coverage fractions remain
      // Reader geometry facts; playback only needs current/target membership
      // while the gesture is active.
      discretePages:
          discretePages && observation.direction != ReadingDirection.vertical,
    );
    _viewport = viewport;
    try {
      pipeline.accept(observation);
    } finally {
      // Viewport/presentation is Reader-local consumer state. A demand-lane
      // reconciliation failure may still be reported by the caller, but it
      // must not prevent the visible viewport/playback projection advancing.
      // Do not re-run PlaybackGate for every continuous coverage fraction:
      // only semantic viewport state or upload-plan identity can change it.
      _syncPlayback(viewport);
    }
  }

  bool classifyPage({
    required int pageIndex,
    required bool animated,
    bool? localPresentationReady,
  }) {
    if (_detached) return false;
    return pipeline.classifyPage(
      pageIndex: pageIndex,
      animated: animated,
      localPresentationReady: localPresentationReady,
    );
  }

  bool observeWebpTransportCost({
    required int pageIndex,
    required bool webp,
  }) {
    if (_detached) return false;
    return pipeline.observeWebpTransportCost(
      pageIndex: pageIndex,
      webp: webp,
    );
  }

  bool observeDecodeWaterline({
    required int planRevision,
    required String stage,
  }) {
    if (_detached) return false;
    return pipeline.observeDecodeWaterline(
      planRevision: planRevision,
      stage: stage,
    );
  }

  void updateDecodeTarget(DecodeTarget target) {
    if (_detached) {
      throw StateError('reader binding is detached');
    }
    pipeline.updateDecodeTarget(target);
  }

  /// Reconciles every outstanding demand to empty before this binding is
  /// replaced or the reader session leaves the widget tree.
  ///
  /// This matters for live coordinators: constructing a new PipelineController
  /// starts its diff history from an empty plan and therefore cannot remove
  /// decode identities owned by the prior physical viewport target.
  void detach(String sessionId) {
    if (_detached) {
      return;
    }
    _detached = true;
    final previous = pipeline.currentPlan;
    if (previous.downloads.isEmpty &&
        previous.decodes.isEmpty &&
        previous.uploads.isEmpty &&
        previous.keep.isEmpty) {
      return;
    }
    final empty = DemandPlan.empty(revision: pipeline.revision + 1);
    _coordinator.reconcile(
      sessionId,
      PipelineDelta(
        plan: empty,
        diff: DemandDiff.between(previous, empty),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
  }

  void _onUpdate(PipelineDelta update) {
    final observation = _observation;
    if (observation == null) {
      throw StateError('pipeline update has no reader observation');
    }
    _coordinator.reconcile(observation.sessionId, update);
  }

  void resyncPlayback() {
    final viewport = _viewport;
    if (_detached || viewport == null) {
      return;
    }
    _syncPlayback(viewport, force: true);
  }

  void _syncPlayback(ViewportState viewport, {bool force = false}) {
    final revision = pipeline.revision;
    if (!force &&
        _playbackPlanRevision == revision &&
        _sameViewportState(_playbackViewport, viewport)) {
      return;
    }
    _playback.syncPlayback(viewport, _uploadIds(pipeline.currentPlan));
    _playbackViewport = viewport;
    _playbackPlanRevision = revision;
  }

  Map<int, DecodeId> _uploadIds(DemandPlan plan) {
    if (_cachedUploadRevision == plan.revision) {
      return _cachedUploadIds;
    }
    final result = <int, DecodeId>{};
    for (final id in plan.uploads.keys) {
      final index = _pageIndexes[id.download.content.pageId];
      if (index != null) {
        result[index] = id;
      }
    }
    _cachedUploadRevision = plan.revision;
    _cachedUploadIds = Map<int, DecodeId>.unmodifiable(result);
    return _cachedUploadIds;
  }

  bool _sameViewportState(ViewportState? a, ViewportState b) =>
      a != null &&
      a.phase == b.phase &&
      a.currentPageIndex == b.currentPageIndex &&
      a.targetPageIndex == b.targetPageIndex &&
      a.dominantPageIndex == b.dominantPageIndex;
}
