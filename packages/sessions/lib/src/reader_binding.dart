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
        _viewportResolver = viewportResolver {
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
  late final PipelineController pipeline;

  ReaderObs? _observation;
  ViewportState? _viewport;
  bool _detached = false;

  ViewportState? get viewport => _viewport;
  int get revision => pipeline.revision;

  void accept(ReaderObs observation) {
    if (_detached) {
      throw StateError('reader binding is detached');
    }
    _observation = observation;
    pipeline.accept(observation);
    _syncViewport(observation);
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

  void _syncViewport(ReaderObs observation) {
    final viewport = _viewportResolver.resolve(
      observation,
      discretePages: discretePages,
    );
    _viewport = viewport;
    _playback.syncPlayback(viewport, _decodeIds(pipeline.currentPlan));
  }

  Map<int, DecodeId> _decodeIds(DemandPlan plan) {
    final pageIndexes = <String, int>{
      for (final page in chapter.pages) page.pageId: page.index,
    };
    final result = <int, DecodeId>{};
    for (final id in <DecodeId>{
      ...plan.decodes.keys,
      ...plan.uploads.keys,
    }) {
      final index = pageIndexes[id.download.content.pageId];
      if (index != null) {
        result[index] = id;
      }
    }
    return result;
  }
}
