import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

import 'animated_prefetch_policy.dart';
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
  int _animatedPrefetchStage = 0;

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
      _animatedPrefetchStage = 0;
    }
    _currentIndex = observation.currentIndex;
    _lastObservation = observation;
    _replan(observation, force: false);
  }

  bool classifyPage({required int pageIndex, required bool animated}) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final beforePrefetchActive = pageIndex == _currentIndex
        ? _animatedPrefetchActiveFor(pageIndex)
        : false;
    final current = _runtimeAnimatedPages[pageIndex];
    if (current == animated) return false;
    _runtimeAnimatedPages[pageIndex] = animated;
    if (pageIndex == _currentIndex &&
        beforePrefetchActive != _animatedPrefetchActiveFor(pageIndex)) {
      _animatedPrefetchStage = 0;
    }
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  /// Advances the animated-WebP network admission window from completed decode
  /// waterline evidence. The callback is revision-scoped so stale work from a
  /// previous page/session cannot reopen speculative downloads after a jump.
  bool observeDecodeWaterline({
    required int planRevision,
    required String stage,
  }) {
    final observation = _lastObservation;
    final current = _currentIndex;
    if (observation == null ||
        current == null ||
        planRevision != _revision ||
        !_animatedPrefetchActiveFor(current)) {
      return false;
    }
    final requested = policy.animatedPrefetchPolicy
        .expansionStageForWaterline(stage);
    if (requested <= _animatedPrefetchStage) return false;
    _animatedPrefetchStage = requested;
    _replan(observation, force: true);
    return true;
  }

  bool _animatedPrefetchActiveFor(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final runtime = _runtimeAnimatedPages[pageIndex];
    if (runtime != null) return runtime;
    final page = chapter.pages[pageIndex];
    if (page.animatedHint) return true;
    // URI/content-kind WebP is only a conservative network-cost hint here; it
    // is not promoted to runtime animation truth. An actual static decode
    // immediately restores the full static-oriented 3/7 admission window.
    if (page.contentKindHint == ContentKindHint.webp ||
        page.uri.path.toLowerCase().endsWith('.webp')) {
      return true;
    }
    // Once this Reader has proved an animated page, unresolved neighbors are
    // conservatively treated as expensive until their own decode says static.
    return _runtimeAnimatedPages.values.any((animated) => animated);
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
    final animatedPrefetchActive =
        _animatedPrefetchActiveFor(observation.currentIndex);
    final animatedPrefetchAdmission = policy.animatedPrefetchPolicy.admit(
      chapter: chapter,
      observation: observation,
      window: window,
      active: animatedPrefetchActive,
      expansionStage: _animatedPrefetchStage,
    );
    final proposal = policy.createPlan(
      revision: _revision,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: _decodeTarget,
      runtimeAnimatedPages: _runtimeAnimatedPages,
      assumeUnresolvedStatic: _assumeUnresolvedStatic,
      downloadAdmission: animatedPrefetchAdmission,
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
          'animatedPrefetchActive': animatedPrefetchAdmission.active,
          'animatedPrefetchStage': animatedPrefetchAdmission.expansionStage,
          'animatedPrefetchBudgetBytes':
              policy.animatedPrefetchPolicy.maxSpeculativeBytes,
          'animatedPrefetchEstimatedBytes':
              animatedPrefetchAdmission.estimatedSpeculativeBytes,
          'animatedPrefetchMinimumExceededBudget':
              animatedPrefetchAdmission.minimumExceedsBudget,
          'animatedPrefetchAdmittedIndexes':
              animatedPrefetchAdmission.admittedIndexes.toList(growable: false)
                ..sort(),
          'currentIndex': observation.currentIndex,
          'targetIndex': observation.targetCoverage?.pageIndex,
          'retainedIndex': window.retainedIndex,
          'interaction': observation.interaction.name,
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
