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
    required DecodeTarget decodeTarget,
    required this.clock,
    required PipelineCallback onUpdate,
    this.traceSink = const NoopTraceSink(),
    this.windowResolver = const RoleResolver(),
    this.policy = const HeuristicPolicy(),
    this.guard = const PolicyGuard(),
  })  : _decodeTarget = decodeTarget,
        _onUpdate = onUpdate;

  final ChapterManifest chapter;
  DecodeTarget _decodeTarget;
  final MonoClock clock;
  final TraceSink traceSink;
  final RoleResolver windowResolver;
  final HeuristicPolicy policy;
  final PolicyGuard guard;
  final PipelineCallback _onUpdate;

  int _revision = 0;
  bool _decodeTargetDirty = false;
  DemandPlan _previous = DemandPlan.empty();
  Map<int, PageRole>? _previousRoles;
  int? _previousRetainedIndex;
  int? _currentIndex;
  int? _lastCurrentIndex;
  ReaderObs? _lastObservation;
  final Map<int, bool> _runtimeAnimatedPages = <int, bool>{};

  int get revision => _revision;
  DemandPlan get currentPlan => _previous;
  DecodeTarget get decodeTarget => _decodeTarget;

  /// Updates only the decode/upload projection target. Physical download
  /// identity and Reader navigation are independent from viewport raster size.
  /// The next observation performs one incremental diff from the existing plan
  /// rather than detaching all demand to empty first.
  void updateDecodeTarget(DecodeTarget target) {
    if (_decodeTarget == target) return;
    _decodeTarget = target;
    _decodeTargetDirty = true;
  }

  void accept(ReaderObs observation) {
    if (_currentIndex != null && _currentIndex != observation.currentIndex) {
      _lastCurrentIndex = _currentIndex;
    }
    _currentIndex = observation.currentIndex;
    _lastObservation = observation;
    _replan(observation, force: false);
  }

  bool classifyPage({required int pageIndex, required bool animated}) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final current = _runtimeAnimatedPages[pageIndex] ??
        chapter.pages[pageIndex].animatedHint;
    if (current == animated) return false;
    _runtimeAnimatedPages[pageIndex] = animated;
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  bool get _assumeUnresolvedStatic {
    var staticCount = 0;
    for (final animated in _runtimeAnimatedPages.values) {
      if (animated) return false;
      staticCount++;
    }
    return staticCount >= 2;
  }

  void _replan(ReaderObs observation, {required bool force}) {
    final window = windowResolver.resolve(
      chapter,
      observation,
      previousCurrentIndex: _lastCurrentIndex,
    );
    if (!force &&
        !_decodeTargetDirty &&
        _sameRoles(_previousRoles, window.roles) &&
        _previousRetainedIndex == window.retainedIndex) {
      return;
    }
    _previousRoles = Map<int, PageRole>.unmodifiable(window.roles);
    _previousRetainedIndex = window.retainedIndex;
    _revision++;
    final proposal = policy.createPlan(
      revision: _revision,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: _decodeTarget,
      runtimeAnimatedPages: _runtimeAnimatedPages,
      assumeUnresolvedStatic: _assumeUnresolvedStatic,
    );
    final plan = guard.enforce(proposal);
    final diff = DemandDiff.between(_previous, plan);
    _previous = plan;
    _decodeTargetDirty = false;

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
          'staticWarmDecodes': plan.decodes.values
              .where((demand) => demand.reason.startsWith('heuristic:static-warm'))
              .length,
          'staticWarmUploads': plan.uploads.values
              .where((demand) => demand.reason.startsWith('heuristic:static-warm'))
              .length,
          'visibleIndexes': observation.visibleCoverages
              .map((coverage) => coverage.pageIndex)
              .toList(growable: false),
          'runtimeStaticPages': _runtimeAnimatedPages.values
              .where((animated) => !animated)
              .length,
          'assumeUnresolvedStatic': _assumeUnresolvedStatic,
          'currentIndex': observation.currentIndex,
          'targetIndex': observation.targetCoverage?.pageIndex,
          'retainedIndex': window.retainedIndex,
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
