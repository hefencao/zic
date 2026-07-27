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
    required FakeCoordinator coordinator,
    TraceSink traceSink = const NoopTraceSink(),
    ViewportResolver viewportResolver = const ViewportResolver(),
    this.discretePages = true,
  })  : _coordinator = coordinator,
        _viewportResolver = viewportResolver {
    pipeline = PipelineController(
      chapter: chapter,
      decodeTarget: decodeTarget,
      clock: clock,
      traceSink: traceSink,
      onUpdate: _onUpdate,
    );
  }

  final ChapterManifest chapter;
  final bool discretePages;
  final FakeCoordinator _coordinator;
  final ViewportResolver _viewportResolver;
  late final PipelineController pipeline;

  ReaderObs? _observation;
  ViewportState? _viewport;

  ViewportState? get viewport => _viewport;

  void accept(ReaderObs observation) {
    _observation = observation;
    pipeline.accept(observation);
  }

  void _onUpdate(PipelineDelta update) {
    final observation = _observation;
    if (observation == null) {
      throw StateError('pipeline update has no reader observation');
    }
    _coordinator.reconcile(observation.sessionId, update);

    final playback = _coordinator;
    if (playback is! PlaybackCoordinator) {
      return;
    }
    final viewport = _viewportResolver.resolve(
      observation,
      discretePages: discretePages,
    );
    _viewport = viewport;
    playback.syncPlayback(viewport, _decodeIds(update.plan));
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
