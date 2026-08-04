import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

import 'demand.dart';
import 'decode_target.dart';
import 'heuristic_policy.dart';
import 'policy_guard.dart';
import 'role_window.dart';

final class PipelineDelta {
  const PipelineDelta({
    required this.plan,
    required this.diff,
    required this.window,
  });

  final DemandPlan plan;
  final DemandDiff diff;
  final RoleWindow window;
}

typedef PipelineCallback = void Function(PipelineDelta update);

final class PipelineController {
  PipelineController({
    required this.chapter,
    required this.decodeTarget,
    required this.clock,
    required PipelineCallback onUpdate,
    this.traceSink = const NoopTraceSink(),
    this.windowResolver = const RoleResolver(),
    this.policy = const HeuristicPolicy(),
    this.guard = const PolicyGuard(),
  }) : _onUpdate = onUpdate;

  final ChapterManifest chapter;
  final DecodeTarget decodeTarget;
  final MonoClock clock;
  final TraceSink traceSink;
  final RoleResolver windowResolver;
  final HeuristicPolicy policy;
  final PolicyGuard guard;
  final PipelineCallback _onUpdate;

  int _revision = 0;
  DemandPlan _previous = DemandPlan.empty();
  Map<int, PageRole>? _previousRoles;
  int? _currentIndex;
  int? _lastCurrentIndex;

  int get revision => _revision;
  DemandPlan get currentPlan => _previous;

  void accept(ReaderObs observation) {
    if (_currentIndex != null && _currentIndex != observation.currentIndex) {
      _lastCurrentIndex = _currentIndex;
    }
    _currentIndex = observation.currentIndex;
    final window = windowResolver.resolve(
      chapter,
      observation,
      previousCurrentIndex: _lastCurrentIndex,
    );
    if (_sameRoles(_previousRoles, window.roles)) {
      return;
    }
    _previousRoles = Map<int, PageRole>.unmodifiable(window.roles);
    _revision++;
    final proposal = policy.createPlan(
      revision: _revision,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: decodeTarget,
    );
    final plan = guard.enforce(proposal);
    final diff = DemandDiff.between(_previous, plan);
    _previous = plan;

    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: observation.sessionId,
        kind: TraceEventKind.policyDecision,
        revision: _revision,
        payload: <String, Object?>{
          'downloads': plan.downloads.length,
          'decodes': plan.decodes.length,
          'uploads': plan.uploads.length,
          'currentIndex': observation.currentIndex,
          'targetIndex': observation.targetCoverage?.pageIndex,
        },
      ),
    );
    _onUpdate(PipelineDelta(plan: plan, diff: diff, window: window));
  }
}


bool _sameRoles(Map<int, PageRole>? previous, Map<int, PageRole> next) {
  if (previous == null || previous.length != next.length) {
    return false;
  }
  for (final entry in next.entries) {
    if (previous[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
